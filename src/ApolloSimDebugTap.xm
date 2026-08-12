// Simulator-only debug bridge: synthesize a real UITouch tap inside the app.
//
// idb_companion 1.1.8's HID events are silently dropped by Xcode 27's iOS-27
// simulators, so there is currently no external way to tap the sim from
// scripts. This module lets the host drive taps through the injected tweak
// instead: write "x y" (screen points) to /tmp/apollofix-tap.txt, then post
// the Darwin notification:
//
//   echo "200 560" > /tmp/apollofix-tap.txt
//   xcrun simctl spawn <UDID> notifyutil -p apollofix.debugtap
//
// The synthesized touch goes through -[UIApplication sendEvent:], so it
// exercises genuine hit-testing, responder-chain bubbling, gesture
// recognizers, and ASControlNode tracking — unlike calling handlers directly.
// Never compiled into device builds.
#if APOLLO_SIM_BUILD

#import "ApolloAccountCredentials.h"
#import "ApolloCommentVoteInsights.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "UIWindow+Apollo.h"
#import "ipad/ApolloPaneSplitViewController.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface UITouch (ApolloSimDebugTap)
- (void)setPhase:(UITouchPhase)phase;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)first;
@end

@interface UIEvent (ApolloSimDebugTap)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setTimestamp:(NSTimeInterval)timestamp;
@end

@interface UIApplication (ApolloSimDebugTap)
- (UIEvent *)_touchesEvent;
@end

static NSString *const kApolloSimTapFile = @"/tmp/apollofix-tap.txt";

@interface ApolloPaneTransitionProbeViewController : UIViewController
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end

@implementation ApolloPaneTransitionProbeViewController {
    NSString *_probeIdentifier;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _probeIdentifier = [identifier copy] ?: @"unnamed";
        self.title = [NSString stringWithFormat:@"Transition Probe %@", _probeIdentifier];
    }
    return self;
}

- (void)loadView {
    UIView *view = [UIView new];
    view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    label.text = self.title;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.centerYAnchor],
    ]];
    self.view = view;
}

@end

static void ApolloSimDebugSendTouch(UITouch *touch) {
    UIApplication *app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(_touchesEvent)]) return;
    UIEvent *event = [app _touchesEvent];
    if ([touch respondsToSelector:@selector(setTimestamp:)]) {
        [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    if ([event respondsToSelector:@selector(_setTimestamp:)]) {
        [event _setTimestamp:NSProcessInfo.processInfo.systemUptime];
    }
    [event _clearTouches];
    [event _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:event];
}

static void ApolloSimDebugPerformTap(CGPoint point) {
    // Hit-test every visible window from topmost down, not just the key
    // window: alert/overlay windows sit above it, and key-window-only taps
    // sailed straight through their chrome into the app underneath.
    UIView *hitView = nil;
    UIWindow *window = nil;
    NSArray<UIWindow *> *ordered = [ApolloAllWindows() sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIWindow *candidate in ordered) {
        if (candidate.hidden) continue;
        UIView *hit = [candidate hitTest:point withEvent:nil];
        if (hit) { window = candidate; hitView = hit; break; }
    }
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for (%.0f, %.0f)", point.x, point.y);
        return;
    }
    ApolloLog(@"[SimDebugTap] tapping (%.0f, %.0f) hit=%@", point.x, point.y,
              NSStringFromClass(hitView.class));

    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) {
        ApolloLog(@"[SimDebugTap] UITouch private setters unavailable on this runtime");
        return;
    }
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] tap delivered");
    });
}

// "hold x y" command: a stationary touch held long enough to trigger ordinary
// UILongPressGestureRecognizer interactions. This is separate from swipe so a
// long-press test doesn't inject tiny moved phases that can trip movement limits.
static void ApolloSimDebugPerformHold(CGPoint point) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for hold (%.0f, %.0f)", point.x, point.y);
        return;
    }
    ApolloLog(@"[SimDebugTap] holding (%.0f, %.0f) hit=%@", point.x, point.y,
              NSStringFromClass(hitView.class));

    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    // A real finger produces stationary samples while it is held. Supplying one
    // gives UIKit's long-press timers a fresh event to advance against in the
    // simulator's synthesized UIEvent stream.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseStationary];
        ApolloSimDebugSendTouch(touch);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] hold delivered");
    });
}

// "swipe x1 y1 x2 y2" command: a real drag (began → moved steps → ended) so a
// scroll view actually scrolls, unlike the single tap above. Reuses the same
// synthesized-touch delivery path.
static void ApolloSimDebugPerformSwipe(CGPoint start, CGPoint end) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:start withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for swipe start (%.0f, %.0f)", start.x, start.y);
        return;
    }
    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
    [touch _setLocationInWindow:start resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    const int steps = 12;
    for (int i = 1; i <= steps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.012 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGFloat t = (CGFloat)i / steps;
            CGPoint p = CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
            [touch _setLocationInWindow:p resetPrevious:NO];
            [touch setPhase:UITouchPhaseMoved];
            ApolloSimDebugSendTouch(touch);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((steps * 0.012 + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:end resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] swipe delivered (%.0f,%.0f)->(%.0f,%.0f)", start.x, start.y, end.x, end.y);
    });
}

// "press x y seconds" command: touch down, hold stationary, touch up. Drives
// UILongPressGestureRecognizer and UIContextMenuInteraction, which idb's
// synthesized HID events fail to trigger reliably.
static void ApolloSimDebugPerformPress(CGPoint point, NSTimeInterval duration) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!window || !hitView) {
        ApolloLog(@"[SimDebugTap] no window/hit view for press (%.0f, %.0f)", point.x, point.y);
        return;
    }
    UITouch *touch = [UITouch new];
    if (![touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)] ||
        ![touch respondsToSelector:@selector(setPhase:)]) return;
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) [touch _setIsFirstTouchForView:YES];
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    ApolloSimDebugSendTouch(touch);

    // Stationary "moved" ticks keep the touch alive for recognizers that
    // sample continuously; a long press tolerates zero movement.
    const NSTimeInterval tick = 0.1;
    for (NSTimeInterval elapsed = tick; elapsed < duration; elapsed += tick) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(elapsed * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch _setLocationInWindow:point resetPrevious:NO];
            [touch setPhase:UITouchPhaseStationary];
            ApolloSimDebugSendTouch(touch);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:point resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] press delivered (%.0f,%.0f) duration=%.2f",
                  point.x, point.y, duration);
    });
}

// "dump" command: write the full view hierarchy of every window (class, frame
// in window coords, hidden/alpha/backgroundColor) to /tmp/apollofix-dump.txt so
// the host can inspect z-order and geometry without a debugger attached.
static void ApolloSimDebugDumpView(UIView *view, UIWindow *window, NSInteger depth, NSMutableString *out) {
    CGRect winFrame = [view.superview convertRect:view.frame toView:window];
    NSString *pad = [@"" stringByPaddingToLength:MIN(depth, 40) * 2 withString:@" " startingAtIndex:0];
    UIColor *bg = view.backgroundColor;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSString *bgDesc = @"nil";
    if (bg && [bg getRed:&r green:&g blue:&b alpha:&a]) {
        bgDesc = [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    } else if (bg) {
        bgDesc = bg.description;
    }
    [out appendFormat:@"%@%@ frame=(%.1f,%.1f,%.1f,%.1f)%@ alpha=%.2f bg=%@\n",
        pad, NSStringFromClass(view.class),
        winFrame.origin.x, winFrame.origin.y, winFrame.size.width, winFrame.size.height,
        view.hidden ? @" HIDDEN" : @"", view.alpha, bgDesc];
    for (UIView *subview in view.subviews) {
        ApolloSimDebugDumpView(subview, window, depth + 1, out);
    }
}

static void ApolloSimDebugDumpHierarchy(void) {
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *window in ApolloAllWindows()) {
        [out appendFormat:@"=== window %@ hidden=%d level=%.0f ===\n",
            NSStringFromClass(window.class), window.hidden, (double)window.windowLevel];
        ApolloSimDebugDumpView(window, window, 0, out);
    }
    [out writeToFile:@"/tmp/apollofix-dump.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ApolloLog(@"[SimDebugTap] hierarchy dump written (%lu bytes)", (unsigned long)out.length);
}

static UIResponder *ApolloSimDebugFirstResponder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *responder = ApolloSimDebugFirstResponder(subview);
        if (responder) return responder;
    }
    return nil;
}

// "text <string>" command: insert into the focused field through UIKeyInput,
// which fires the same editing events as typing.
static void ApolloSimDebugTypeText(NSString *text) {
    UIResponder *responder = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        responder = ApolloSimDebugFirstResponder(window);
        if (responder) break;
    }
    if (![responder conformsToProtocol:@protocol(UIKeyInput)]) {
        ApolloLog(@"[SimDebugTap] no key-input first responder for text command");
        return;
    }
    [(id<UIKeyInput>)responder insertText:text];
    ApolloLog(@"[SimDebugTap] typed %lu chars into %@",
              (unsigned long)text.length, NSStringFromClass(responder.class));
}

// "crash <type>" command: deliberately crash the process to exercise the
// local crash recorder (src/crash/). Types mirror the crash-capture test
// plan: nsexception, abort, badaccess, overflow.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winfinite-recursion"
__attribute__((noinline)) static void ApolloSimDebugRecursiveCrash(volatile NSUInteger value) {
    volatile NSUInteger next = value + 1;
    ApolloSimDebugRecursiveCrash(next);
}
#pragma clang diagnostic pop

static void ApolloSimDebugPerformCrash(NSString *type) {
    ApolloLog(@"[SimDebugTap] deliberate test crash: %@", type);
    if ([type isEqualToString:@"nsexception"]) {
        [@[] objectAtIndex:1];
    } else if ([type isEqualToString:@"abort"]) {
        abort();
    } else if ([type isEqualToString:@"badaccess"]) {
        *(volatile int *)0 = 1;
    } else if ([type isEqualToString:@"overflow"]) {
        ApolloSimDebugRecursiveCrash(0);
    }
    ApolloLog(@"[SimDebugTap] unknown crash type: %@", type);
}

// "insetbottom N" command: ask every visible Apollo ASTableView to accept a
// specific bottom inset. This reproduces the iOS 27 foreground write (153 -> 0)
// without depending on the simulator exhibiting the upstream lifecycle bug.
// ApolloListBottomInsetGuard should guard the zero and log the correction.
static void ApolloSimDebugForceBottomInsetInView(UIView *view, CGFloat bottom) {
    if ([view isKindOfClass:objc_getClass("ASTableView")] && view.window) {
        UIScrollView *scrollView = (UIScrollView *)view;
        UIEdgeInsets inset = scrollView.contentInset;
        CGFloat before = inset.bottom;
        inset.bottom = bottom;
        scrollView.contentInset = inset;
        ApolloLog(@"[SimDebugTap] insetbottom requested=%.1f before=%.1f after=%.1f table=%@",
                  bottom, before, scrollView.contentInset.bottom,
                  NSStringFromClass(scrollView.class));
    }
    for (UIView *subview in view.subviews) {
        ApolloSimDebugForceBottomInsetInView(subview, bottom);
    }
}

static void ApolloSimDebugForceBottomInset(CGFloat bottom) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.hidden) ApolloSimDebugForceBottomInsetInView(window, bottom);
    }
}

// Stamp-key accessors exported by ApolloScrollEdgeEffect.xm (both files are
// ObjC++, so plain C++ linkage matches).
const void *ApolloScrollEdgeEffectTopStampKey(void);
const void *ApolloScrollEdgeEffectForcedHiddenStampKey(void);

static void ApolloSimDebugDumpHeaderEffectsInView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        SEL topSelector = NSSelectorFromString(@"topEdgeEffect");
        if ([view respondsToSelector:topSelector]) {
            id effect = ((id (*)(id, SEL))objc_msgSend)(view, topSelector);
            if (effect) {
                BOOL hidden = ((BOOL (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"isHidden"));
                id style = ((id (*)(id, SEL))objc_msgSend)(effect, NSSelectorFromString(@"style"));
                ApolloLog(@"[SimDebugTap][headerdump] scroll=%@ window=%d effect=%p hidden=%d style=%@ topStamp=%d forcedStamp=%d",
                          NSStringFromClass(view.class), view.window != nil, effect, hidden, style,
                          objc_getAssociatedObject(effect, ApolloScrollEdgeEffectTopStampKey()) != nil,
                          objc_getAssociatedObject(effect, ApolloScrollEdgeEffectForcedHiddenStampKey()) != nil);
            }
        }
    }
    for (UIView *subview in view.subviews) ApolloSimDebugDumpHeaderEffectsInView(subview);
}

static void ApolloSimDebugDumpHeaderEffects(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.hidden) ApolloSimDebugDumpHeaderEffectsInView(window);
    }
}

// Overriding the child's traits from its parent is the supported way to force a
// size class on one subtree; passing nil restores inheritance. Matching on
// UISplitViewController keeps this generic — no dependency on src/ipad/.
static void ApolloSimDebugForceCompactSplitColumns(BOOL compact) {
    UIViewController *tabBarController = ApolloMainTabBarController();
    if (![tabBarController isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[SimDebugTap] compact: no tab bar controller");
        return;
    }

    UITraitCollection *override = compact
        ? [UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassCompact]
        : nil;

    NSUInteger applied = 0;
    for (UIViewController *child in [(UITabBarController *)tabBarController viewControllers]) {
        if (![child isKindOfClass:[UISplitViewController class]]) continue;
        [tabBarController setOverrideTraitCollection:override forChildViewController:child];
        applied++;
    }
    ApolloLog(@"[SimDebugTap] compact=%d applied to %lu split controller(s)",
              compact, (unsigned long)applied);
}

// "accessibilityescape": invoke the same action VoiceOver's two-finger scrub
// sends to the visible pane. This validates the compact cross-column escape
// path without relying on simulator HID support for accessibility gestures.
static void ApolloSimDebugPerformAccessibilityEscape(void) {
    UIViewController *controller = ApolloMainTabBarController();
    UIViewController *selected = [controller isKindOfClass:[UITabBarController class]]
        ? ((UITabBarController *)controller).selectedViewController : nil;
    BOOL handled = [selected accessibilityPerformEscape];
    ApolloLog(@"[SimDebugTap] accessibility escape handled=%d selected=%@",
              handled, NSStringFromClass(selected.class));
}

// "visibleprobe dump|alert|share|dismiss": exercise the same recursive
// visible-controller helper used by production presentation call sites and log
// the concrete presenter relationship. The share probe configures a popover
// anchor so an incorrect iPad presenter fails as a hierarchy bug, not because
// UIActivityViewController itself was incompletely configured.
static void ApolloSimDebugVisiblePresenterProbe(NSString *operation) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (!candidate.hidden && candidate.alpha > 0.01 && candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    if (!window) {
        for (UIWindow *candidate in ApolloAllWindows()) {
            if (!candidate.hidden && candidate.alpha > 0.01 && candidate.windowLevel == UIWindowLevelNormal) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *visible = window.visibleViewController;
    NSString *name = NSStringFromClass(visible.class) ?: @"nil";
    ApolloLog(@"[SimDebugTap][visibleprobe] operation=%@ visible=%@ attached=%d window=%@",
              operation, name, visible.viewIfLoaded.window != nil,
              NSStringFromClass(window.class));

    if ([operation isEqualToString:@"dump"] || !visible) return;
    if ([operation isEqualToString:@"dismiss"]) {
        [window.rootViewController dismissViewControllerAnimated:NO completion:^{
            ApolloLog(@"[SimDebugTap][visibleprobe] dismissed");
        }];
        return;
    }

    UIViewController *probe = nil;
    if ([operation isEqualToString:@"alert"]) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Pane Presenter Probe"
                             message:name
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        probe = alert;
    } else if ([operation isEqualToString:@"share"]) {
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:@[ @"Apollo pane presenter probe" ] applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        popover.sourceView = visible.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(visible.view.bounds),
                                        CGRectGetMidY(visible.view.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
        probe = activity;
    }
    if (!probe) {
        ApolloLog(@"[SimDebugTap][visibleprobe] unknown operation %@", operation);
        return;
    }

    [visible presentViewController:probe animated:NO completion:^{
        UIViewController *actual = probe.presentingViewController;
        BOOL sameBranch = actual == visible ||
            ApolloViewControllerContains(actual, visible) ||
            ApolloViewControllerContains(visible, actual);
        ApolloLog(@"[SimDebugTap][visibleprobe] presented=%@ requested=%@ actual=%@ sameBranch=%d",
                  NSStringFromClass(probe.class), NSStringFromClass(visible.class),
                  NSStringFromClass(actual.class), sameBranch);
    }];
}

// "navdump" command: prove which real navigation stacks the shared tab-child
// helpers expose. This catches a subtle pane regression that a screenshot cannot:
// UIKit owns an outer wrapper navigation controller around the secondary host,
// while Apollo's visible detail stack is a different navigation controller
// nested inside that host. The dump must list the latter exactly once.
static void ApolloSimDebugDumpNavigationControllers(void) {
    UIViewController *controller = ApolloMainTabBarController();
    if (![controller isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[SimDebugTap] navdump: no tab bar controller");
        return;
    }

    UITabBarController *tabBarController = (UITabBarController *)controller;
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"selected=%lu tabs=%lu\n",
        (unsigned long)tabBarController.selectedIndex,
        (unsigned long)tabBarController.viewControllers.count];
    [tabBarController.viewControllers enumerateObjectsUsingBlock:
        ^(UIViewController *child, NSUInteger tabIndex, BOOL *stop) {
            NSArray<UINavigationController *> *navs = ApolloAllNavigationControllersForTabChild(child);
            UINavigationController *primary = ApolloNavigationControllerForTabChild(child);
            [out appendFormat:@"tab=%lu child=%@ navs=%lu primary=%p\n",
                (unsigned long)tabIndex, NSStringFromClass(child.class),
                (unsigned long)navs.count, primary];
            [navs enumerateObjectsUsingBlock:
                ^(UINavigationController *nav, NSUInteger navIndex, BOOL *innerStop) {
                    NSMutableArray<NSString *> *classes = [NSMutableArray array];
                    for (UIViewController *stackController in nav.viewControllers) {
                        [classes addObject:NSStringFromClass(stackController.class) ?: @"(unknown)"];
                    }
                    [out appendFormat:@"  nav=%lu ptr=%p primary=%d parent=%@ stack=[%@]\n",
                        (unsigned long)navIndex, nav, nav == primary,
                        NSStringFromClass(nav.parentViewController.class),
                        [classes componentsJoinedByString:@", "]];
                }];
        }];
    [out writeToFile:@"/tmp/apollofix-navcontrollers.txt"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ApolloLog(@"[SimDebugTap] navigation-controller dump written (%lu bytes)",
              (unsigned long)out.length);
}

// "loadstatus" command: inspect lazy pane materialization without touching any
// unloaded view. This makes Task 15's cold-launch contract directly observable:
// construction may wrap all tab stacks, but only a visited tab may load its
// pane/column hierarchy.
static void ApolloSimDebugDumpPaneLoadStatus(void) {
    UIViewController *controller = ApolloMainTabBarController();
    if (![controller isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[PaneLoadTest] no tab bar controller pass=0");
        return;
    }

    UITabBarController *tabBarController = (UITabBarController *)controller;
    NSMutableString *out = [NSMutableString stringWithFormat:@"selected=%lu tabs=%lu\n",
        (unsigned long)tabBarController.selectedIndex,
        (unsigned long)tabBarController.viewControllers.count];
    __block NSUInteger loadedPaneCount = 0;
    __block NSUInteger attachedPaneCount = 0;
    __block BOOL selectedPaneLoaded = NO;
    [tabBarController.viewControllers enumerateObjectsUsingBlock:
        ^(UIViewController *child, NSUInteger tabIndex, BOOL *stop) {
            if (![child isKindOfClass:[ApolloPaneSplitViewController class]]) {
                [out appendFormat:@"tab=%lu child=%@ pane=0\n", (unsigned long)tabIndex,
                    NSStringFromClass(child.class)];
                return;
            }
            ApolloPaneSplitViewController *pane = (ApolloPaneSplitViewController *)child;
            UINavigationController *primary =
                [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
            UINavigationController *detail =
                [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
            UIViewController *host =
                [pane viewControllerForColumn:UISplitViewControllerColumnSecondary];
            BOOL paneLoaded = pane.isViewLoaded;
            if (paneLoaded) loadedPaneCount++;
            BOOL attached = pane.viewIfLoaded.window != nil;
            if (attached) attachedPaneCount++;
            if (tabIndex == tabBarController.selectedIndex) selectedPaneLoaded = paneLoaded;
            [out appendFormat:
                @"tab=%lu paneLoaded=%d primaryLoaded=%d detailLoaded=%d hostLoaded=%d "
                 "primaryRootLoaded=%d detailRootLoaded=%d attached=%d\n",
                (unsigned long)tabIndex, paneLoaded, primary.isViewLoaded,
                detail.isViewLoaded, host.isViewLoaded,
                primary.viewControllers.firstObject.isViewLoaded,
                detail.viewControllers.firstObject.isViewLoaded,
                attached];
        }];
    [out appendFormat:@"loadedPaneCount=%lu attachedPaneCount=%lu pass=%d\n",
        (unsigned long)loadedPaneCount, (unsigned long)attachedPaneCount,
        selectedPaneLoaded && attachedPaneCount == 1];
    [out writeToFile:@"/tmp/apollofix-pane-load-status.txt"
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ApolloLog(@"[PaneLoadTest] load status written loaded=%lu selected=%lu",
              (unsigned long)loadedPaneCount, (unsigned long)tabBarController.selectedIndex);
}

static UINavigationController *ApolloSimDebugSelectedNavigationController(NSString *columnName) {
    UIViewController *controller = ApolloMainTabBarController();
    UIViewController *selected = [controller isKindOfClass:[UITabBarController class]]
        ? ((UITabBarController *)controller).selectedViewController : nil;
    UINavigationController *primary = ApolloNavigationControllerForTabChild(selected);
    if (![columnName isEqualToString:@"detail"]) return primary;

    for (UINavigationController *candidate in ApolloAllNavigationControllersForTabChild(selected)) {
        if (candidate != primary) return candidate;
    }
    // Compact has one physical stack. Falling back to it lets the same command
    // exercise logical-detail Back before and after an expansion.
    return primary;
}

static ApolloPaneSplitViewController *ApolloSimDebugSelectedPane(void) {
    UIViewController *controller = ApolloMainTabBarController();
    UIViewController *selected = [controller isKindOfClass:[UITabBarController class]]
        ? ((UITabBarController *)controller).selectedViewController : nil;
    return [selected isKindOfClass:[ApolloPaneSplitViewController class]]
        ? (ApolloPaneSplitViewController *)selected : nil;
}

// Task 13 resolved-layout harness. Drive only the selected pane through public
// trait/split APIs so untouched tabs retain their production lazy state.
static void ApolloSimDebugSetPaneMode(NSString *mode) {
    UITabBarController *tabBarController = (UITabBarController *)ApolloMainTabBarController();
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    if (![tabBarController isKindOfClass:[UITabBarController class]] || !pane) {
        ApolloLog(@"[PaneDisplayTest] panemode unavailable");
        return;
    }
    NSString *normalized = mode.lowercaseString;
    if ([normalized isEqualToString:@"compact"]) {
        [pane apollo_simSetResolvedLayoutMode:@"reset"];
        UITraitCollection *compact = [UITraitCollection
            traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassCompact];
        [tabBarController setOverrideTraitCollection:compact forChildViewController:pane];
    } else {
        UITraitCollection *regular = [UITraitCollection
            traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassRegular];
        [tabBarController setOverrideTraitCollection:regular forChildViewController:pane];
        [pane apollo_simSetResolvedLayoutMode:normalized];
        if ([normalized isEqualToString:@"reset"]) {
            [tabBarController setOverrideTraitCollection:nil forChildViewController:pane];
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloLog(@"[PaneDisplayTest] mode=%@ %@", normalized,
                  [pane apollo_simResolvedLayoutState]);
    });
}

static void ApolloSimDebugLogPaneStatus(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    ApolloLog(@"[PaneDisplayTest] status %@",
              pane ? [pane apollo_simResolvedLayoutState] : @"no pane");
}

static void ApolloSimDebugLogMasterSelectionStatus(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    ApolloLog(@"[PaneSelectionTest] %@",
              pane ? [pane apollo_simMasterSelectionState] : @"no pane pass=0");
}

static void ApolloSimDebugClearMasterSelection(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    [pane apollo_clearDetailColumn];
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSimDebugLogMasterSelectionStatus();
    });
}

static void ApolloSimDebugPushSelectionContinuation(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    UINavigationController *detail =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    if (!pane || pane.apollo_detailIsEmpty || !detail) {
        ApolloLog(@"[PaneSelectionTest] continuation unavailable");
        return;
    }
    UIViewController *continuation = [UIViewController new];
    continuation.title = @"Task 14 Continuation";
    continuation.view.backgroundColor = UIColor.systemBackgroundColor;
    [detail pushViewController:continuation animated:NO];
    ApolloLog(@"[PaneSelectionTest] continuation pushed depth=%lu %@",
              (unsigned long)detail.viewControllers.count,
              [pane apollo_simMasterSelectionState]);
}

static void ApolloSimDebugActivateShowList(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    BOOL activated = [pane apollo_simActivateShowPrimaryItem];
    ApolloLog(@"[PaneDisplayTest] activate showlist=%d before={%@}", activated,
              pane ? [pane apollo_simResolvedLayoutState] : @"no pane");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloLog(@"[PaneDisplayTest] activate settled={%@}",
                  pane ? [pane apollo_simResolvedLayoutState] : @"no pane");
    });
}

// Deterministic serialization harness for Task 11. Holding the pane's test gate
// emulates a live transition without relying on Xcode 27's broken HID events.
// Multiple `transitionselect` commands exercise the real push hook and must
// coalesce to the last identifier; `transitiongate off` releases the queue.
static void ApolloSimDebugSetTransitionGate(NSString *operation) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    if (!pane) {
        ApolloLog(@"[SimDebugTap][transition] gate unavailable");
        return;
    }
    if ([operation isEqualToString:@"on"] || [operation isEqualToString:@"off"]) {
        [pane apollo_simSetCrossColumnNavigationBlocked:[operation isEqualToString:@"on"]];
    }
    ApolloLog(@"[SimDebugTap][transition] %@", [pane apollo_simCrossColumnNavigationState]);
}

static void ApolloSimDebugSelectTransitionProbe(NSString *identifier) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    UINavigationController *primary =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    if (!pane || !primary.topViewController) {
        ApolloLog(@"[SimDebugTap][transition] selection unavailable");
        return;
    }
    NSString *normalized = identifier.length > 0 ? identifier : @"unnamed";
    ApolloPaneTransitionProbeViewController *probe =
        [[ApolloPaneTransitionProbeViewController alloc] initWithIdentifier:normalized];
    [primary pushViewController:probe animated:NO];
    UINavigationController *detail =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    ApolloLog(@"[SimDebugTap][transition] selected=%@ immediatePrimary=%@ immediateDetail=%@ state={%@}",
              normalized, primary.topViewController.title ?: @"(nil)",
              detail.topViewController.title ?: @"(nil)",
              [pane apollo_simCrossColumnNavigationState]);
}

static void ApolloSimDebugDumpTransitionState(void) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    UINavigationController *primary =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    UINavigationController *detail =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    ApolloLog(@"[SimDebugTap][transition] primary=%@ depth=%lu detail=%@ depth=%lu state={%@}",
              primary.topViewController.title ?: NSStringFromClass(primary.topViewController.class),
              (unsigned long)primary.viewControllers.count,
              detail.topViewController.title ?: NSStringFromClass(detail.topViewController.class),
              (unsigned long)detail.viewControllers.count,
              pane ? [pane apollo_simCrossColumnNavigationState] : @"no pane");
}

static UIGestureRecognizer *ApolloSimDebugNavigationGesture(UINavigationController *navigationController,
                                                            const char *ivarName) {
    if (!navigationController || !ivarName) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(navigationController.class, ivarName);
        id value = ivar ? object_getIvar(navigationController, ivar) : nil;
        return [value isKindOfClass:[UIGestureRecognizer class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Drive Apollo's real detail edge recognizer while two newer primary selections
// arrive. This is intentionally slower than an ordinary swipe so both pushes
// deterministically land after the recognizer begins and before it terminates.
static BOOL sApolloSimTransitionRaceRunning = NO;

static void ApolloSimDebugRunInteractiveTransitionRace(BOOL shouldCommit) {
    ApolloPaneSplitViewController *pane = ApolloSimDebugSelectedPane();
    UINavigationController *detail =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    if (!pane || pane.isCollapsed || !detail.viewIfLoaded.window ||
        detail.transitionCoordinator || sApolloSimTransitionRaceRunning) {
        ApolloLog(@"[SimDebugTap][transitionrace] detail unavailable");
        return;
    }
    // Always isolate the gesture from real Reddit content. The synthetic Back
    // pops only this inert probe even when the live detail stack was already deep.
    ApolloPaneTransitionProbeViewController *child =
        [[ApolloPaneTransitionProbeViewController alloc] initWithIdentifier:@"Gesture Child"];
    [detail pushViewController:child animated:NO];
    if (detail.viewControllers.count < 2) {
        ApolloLog(@"[SimDebugTap][transitionrace] could not prepare detail child");
        return;
    }

    UIGestureRecognizer *apolloEdge =
        ApolloSimDebugNavigationGesture(detail, "leftScreenEdgePanGestureRecognizer");
    if (!apolloEdge) {
        ApolloLog(@"[SimDebugTap][transitionrace] ERROR Apollo edge recognizer unavailable");
        return;
    }

    UIWindow *window = detail.view.window;
    CGPoint localStart = CGPointMake(8.0, CGRectGetMidY(detail.view.bounds));
    CGPoint localEnd = CGPointMake(shouldCommit ? detail.view.bounds.size.width * 0.72 : 42.0,
                                   localStart.y);
    CGPoint start = [detail.view convertPoint:localStart toView:window];
    CGPoint end = [detail.view convertPoint:localEnd toView:window];
    UIView *hitView = [window hitTest:start withEvent:nil];
    if (!hitView || ![hitView isDescendantOfView:detail.view]) {
        ApolloLog(@"[SimDebugTap][transitionrace] invalid edge hit view=%@", hitView);
        return;
    }

    UITouch *touch = [UITouch new];
    [touch setWindow:window];
    [touch setView:hitView];
    [touch setTapCount:1];
    if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
        [touch _setIsFirstTouchForView:YES];
    }
    [touch _setLocationInWindow:start resetPrevious:YES];
    [touch setPhase:UITouchPhaseBegan];
    sApolloSimTransitionRaceRunning = YES;
    ApolloSimDebugSendTouch(touch);

    const int steps = 24;
    __block BOOL raceVerified = NO;
    for (int index = 1; index <= steps; index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(index * 0.022 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CGFloat progress;
                if (!shouldCommit && index <= 4) {
                    // Cross pan-recognition hysteresis promptly, then crawl to
                    // the cancellation endpoint so terminal velocity stays low.
                    progress = (28.0 - localStart.x) * ((CGFloat)index / 4.0) /
                        (localEnd.x - localStart.x);
                } else if (!shouldCommit) {
                    CGFloat tail = (CGFloat)(index - 4) / (CGFloat)(steps - 4);
                    progress = ((28.0 - localStart.x) +
                        (localEnd.x - 28.0) * tail) / (localEnd.x - localStart.x);
                } else {
                    progress = (CGFloat)index / (CGFloat)steps;
                }
                CGPoint point = CGPointMake(start.x + (end.x - start.x) * progress,
                                            start.y + (end.y - start.y) * progress);
                [touch _setLocationInWindow:point resetPrevious:NO];
                [touch setPhase:UITouchPhaseMoved];
                ApolloSimDebugSendTouch(touch);
            });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id<UIViewControllerTransitionCoordinator> coordinator = detail.transitionCoordinator;
        UIGestureRecognizerState state = apolloEdge.state;
        raceVerified = (state == UIGestureRecognizerStateBegan ||
                        state == UIGestureRecognizerStateChanged) && coordinator.isInteractive;
        ApolloLog(@"[SimDebugTap][transitionrace] verified=%d edgeState=%ld interactive=%d",
                  raceVerified, (long)state, coordinator.isInteractive);
        if (!raceVerified) {
            ApolloLog(@"[SimDebugTap][transitionrace] ERROR interactive transition did not begin");
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (raceVerified) ApolloSimDebugSelectTransitionProbe(@"Race A");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (raceVerified) ApolloSimDebugSelectTransitionProbe(@"Race B");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.56 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:end resetPrevious:NO];
        [touch setPhase:shouldCommit ? UITouchPhaseEnded : UITouchPhaseCancelled];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap][transitionrace] gesture ended commit=%d verified=%d start=(%.0f,%.0f) end=(%.0f,%.0f)",
                  shouldCommit, raceVerified, start.x, start.y, end.x, end.y);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloSimDebugDumpTransitionState();
        sApolloSimTransitionRaceRunning = NO;
    });
}

static NSString *ApolloSimDebugNavigationItemSummary(UINavigationItem *item) {
    NSMutableArray<NSString *> *leftItems = [NSMutableArray array];
    for (UIBarButtonItem *barItem in item.leftBarButtonItems ?: @[]) {
        [leftItems addObject:barItem.title ?: barItem.accessibilityIdentifier ?: @"(untitled)"];
    }
    return [NSString stringWithFormat:@"hides=%d supplements=%d left=[%@] back=%@",
        item.hidesBackButton, item.leftItemsSupplementBackButton,
        [leftItems componentsJoinedByString:@", "],
        item.backBarButtonItem.title ?: item.backButtonTitle ?: @"(nil)"];
}

// "navitemdump [primary|detail]" records the top controller's complete leading-
// item policy so real Apollo destinations can be compared before and after a
// pane route without relying on pixels alone.
static void ApolloSimDebugDumpNavigationItem(NSString *columnName) {
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(columnName);
    UIViewController *top = navigationController.topViewController;
    ApolloLog(@"[SimDebugTap] navitem column=%@ top=%@ depth=%lu %@",
              columnName ?: @"primary", NSStringFromClass(top.class),
              (unsigned long)navigationController.viewControllers.count,
              ApolloSimDebugNavigationItemSummary(top.navigationItem));
}

// "navitemprobe [primary|detail]" pushes an intentionally unknown controller
// whose native policy hides Back and owns a leading item. The pane router must
// leave every property and object identity untouched, then the original stack
// is restored without creating Forward history.
static void ApolloSimDebugProbeUnknownNavigationItem(NSString *columnName) {
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(columnName);
    if (!navigationController) {
        ApolloLog(@"[SimDebugTap] navitemprobe unavailable column=%@", columnName);
        return;
    }
    NSArray<UIViewController *> *originalStack = navigationController.viewControllers;
    UIViewController *probe = [UIViewController new];
    probe.title = @"Unknown Navigation Item Probe";
    UIBarButtonItem *nativeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Native" style:UIBarButtonItemStylePlain target:nil action:nil];
    probe.navigationItem.leftBarButtonItems = @[ nativeItem ];
    probe.navigationItem.hidesBackButton = YES;
    probe.navigationItem.leftItemsSupplementBackButton = NO;

    [navigationController pushViewController:probe animated:NO];
    BOOL retained = navigationController.topViewController == probe &&
        probe.navigationItem.hidesBackButton &&
        !probe.navigationItem.leftItemsSupplementBackButton &&
        probe.navigationItem.leftBarButtonItems.count == 1 &&
        probe.navigationItem.leftBarButtonItems.firstObject == nativeItem;
    ApolloLog(@"[SimDebugTap] navitemprobe column=%@ retained=%d %@",
              columnName ?: @"primary", retained,
              ApolloSimDebugNavigationItemSummary(probe.navigationItem));
    [navigationController setViewControllers:originalStack animated:NO];
}

// "navitemmutate [primary|detail]" simulates a destination changing its own
// leading items and Back policy while compact. Expansion must remove only the
// pane-owned item and preserve these native changes.
static void ApolloSimDebugMutateNavigationItem(NSString *columnName) {
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(columnName);
    UIViewController *top = navigationController.topViewController;
    if (!top) {
        ApolloLog(@"[SimDebugTap] navitemmutate unavailable column=%@", columnName);
        return;
    }
    UIBarButtonItem *dynamicItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Dynamic" style:UIBarButtonItemStylePlain target:nil action:nil];
    dynamicItem.accessibilityIdentifier = @"ApolloPaneTask10Dynamic";
    NSArray<UIBarButtonItem *> *existing = top.navigationItem.leftBarButtonItems ?: @[];
    top.navigationItem.leftBarButtonItems = [existing arrayByAddingObject:dynamicItem];
    top.navigationItem.leftItemsSupplementBackButton = YES;
    top.navigationItem.hidesBackButton = YES;
    ApolloLog(@"[SimDebugTap] navitemmutate column=%@ top=%@ %@",
              columnName ?: @"detail", NSStringFromClass(top.class),
              ApolloSimDebugNavigationItemSummary(top.navigationItem));
}

// "navback [primary|detail]" command: perform the navigation-controller pop that UIKit's Back
// button would request. Xcode 27 currently drops idb HID events, so this keeps
// compact ownership tests deterministic while still exercising the real stack
// mutation and navigation-controller delegate callbacks.
static void ApolloSimDebugPerformNavigationBack(NSString *columnName) {
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(columnName);
    if (navigationController.viewControllers.count <= 1) {
        ApolloLog(@"[SimDebugTap] navback unavailable column=%@ depth=%lu",
                  columnName ?: @"primary",
                  (unsigned long)navigationController.viewControllers.count);
        return;
    }

    UIViewController *popped = [navigationController popViewControllerAnimated:NO];
    ApolloLog(@"[SimDebugTap] navback column=%@ popped=%@ remaining=%@ depth=%lu",
              columnName ?: @"primary",
              NSStringFromClass(popped.class),
              NSStringFromClass(navigationController.topViewController.class),
              (unsigned long)navigationController.viewControllers.count);
}

// "navforward [primary|detail]" pairs with navback and invokes ApolloNavigationController's
// real forward-history action. Re-pushing through that path also passes through
// the pane router, which is the behavior the compact ownership test needs to
// verify before expansion.
static void ApolloSimDebugPerformNavigationForward(NSString *columnName) {
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(columnName);
    SEL forward = NSSelectorFromString(@"goForward");
    if (![navigationController respondsToSelector:forward]) {
        ApolloLog(@"[SimDebugTap] navforward unavailable column=%@ nav=%@",
                  columnName ?: @"primary", NSStringFromClass(navigationController.class));
        return;
    }

    NSUInteger beforeDepth = navigationController.viewControllers.count;
    NSString *beforeTop = NSStringFromClass(navigationController.topViewController.class);
    ((void (*)(id, SEL))objc_msgSend)(navigationController, forward);
    ApolloLog(@"[SimDebugTap] navforward column=%@ nav=%@ depth=%lu->%lu top=%@->%@",
              columnName ?: @"primary",
              NSStringFromClass(navigationController.class),
              (unsigned long)beforeDepth,
              (unsigned long)navigationController.viewControllers.count,
              beforeTop, NSStringFromClass(navigationController.topViewController.class));
}

// "navset primary same|root": deterministically exercise Apollo's
// setViewControllers: entry point. `same` proves a no-op replacement retains a
// valid detail branch; `root` proves removing its owner clears detail and
// forward history. Simulator-only because production never needs a synthetic
// stack mutation.
static void ApolloSimDebugSetNavigationStack(NSString *arguments) {
    NSArray<NSString *> *parts = [arguments componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [tokens addObject:part];
    }
    NSString *column = tokens.count > 0 ? tokens[0] : @"primary";
    NSString *operation = tokens.count > 1 ? tokens[1] : @"same";
    UINavigationController *navigationController =
        ApolloSimDebugSelectedNavigationController(column);
    NSArray<UIViewController *> *before = navigationController.viewControllers;
    NSArray<UIViewController *> *replacement = before;
    if ([operation isEqualToString:@"root"] && before.firstObject) {
        replacement = @[ before.firstObject ];
    }
    [navigationController setViewControllers:replacement animated:NO];
    ApolloLog(@"[SimDebugTap] navset column=%@ operation=%@ depth=%lu->%lu",
              column, operation, (unsigned long)before.count,
              (unsigned long)navigationController.viewControllers.count);
}

// Exercise the same unambiguous active-account notification that production
// observes, without changing or exposing any saved credentials.
static void ApolloSimDebugPostAccountContextChange(void) {
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"com.christianselig.RedditCurrentAccountChanged"
                      object:nil];
    ApolloLog(@"[SimDebugTap] posted active-account context change");
}

// "tab N" command: select a tab through UITabBarController's public API. This
// avoids Xcode 27's broken HID path while still exercising Apollo's ordinary
// tab-child attachment and pane lifecycle for the smoke loop.
static void ApolloSimDebugSelectTab(NSInteger index) {
    UIViewController *controller = ApolloMainTabBarController();
    if (![controller isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[SimDebugTap] tab selection unavailable");
        return;
    }
    UITabBarController *tabBarController = (UITabBarController *)controller;
    if (index < 0 || index >= (NSInteger)tabBarController.viewControllers.count) {
        ApolloLog(@"[SimDebugTap] tab selection out of range: %ld", (long)index);
        return;
    }
    tabBarController.selectedIndex = index;
    ApolloLog(@"[SimDebugTap] selected tab %ld child=%@", (long)index,
              NSStringFromClass(tabBarController.selectedViewController.class));
}

// "routeurl <url>": invoke Apollo's real AppDelegate URL entry point. The
// simulator's URL-scheme dispatcher is unreliable for this re-signed app on
// Xcode 27, so this provides deterministic warm-entry coverage without
// replacing any production routing logic.
static void ApolloSimDebugRouteURL(NSString *rawURL) {
    NSURL *url = [NSURL URLWithString:rawURL];
    BOOL routed = url && ApolloRouteURLThroughApp(url);
    ApolloLog(@"[SimDebugTap] routeurl routed=%d scheme=%@",
              routed, url.scheme.lowercaseString ?: @"invalid");
}

// "useractivity <url>": invoke Apollo's real SceneDelegate Handoff/universal-
// link entry point with a browsing-web activity.
static void ApolloSimDebugContinueUserActivity(NSString *rawURL) {
    NSURL *url = [NSURL URLWithString:rawURL];
    NSString *scheme = url.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        ApolloLog(@"[SimDebugTap] useractivity rejected non-web scheme=%@",
                  scheme ?: @"invalid");
        return;
    }
    NSUserActivity *activity = [[NSUserActivity alloc]
        initWithActivityType:NSUserActivityTypeBrowsingWeb];
    @try {
        activity.webpageURL = url;
    } @catch (NSException *exception) {
        ApolloLog(@"[SimDebugTap] useractivity could not set webpage URL: %@", exception);
        return;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        id delegate = scene.delegate;
        SEL selector = @selector(scene:continueUserActivity:);
        if (![delegate respondsToSelector:selector]) continue;
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, selector, scene, activity);
        ApolloLog(@"[SimDebugTap] useractivity delivered=%d scheme=%@",
                  url != nil, url.scheme.lowercaseString ?: @"invalid");
        return;
    }
    ApolloLog(@"[SimDebugTap] useractivity: no scene delegate accepted the activity");
}

// "shortcut Search" and "shortcut FavoriteSubreddit <name>": drive the two
// exact UIApplicationShortcutItem types Apollo 1.15.11 accepts through the
// real SceneDelegate callback. Search is especially useful here because the
// native implementation indexes viewControllers[3] and casts it to a nav.
static void ApolloSimDebugPerformShortcut(NSString *arguments) {
    NSArray<NSString *> *parts = [arguments componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) if (part.length > 0) [tokens addObject:part];
    NSString *type = tokens.firstObject;
    if (!([type isEqualToString:@"Search"] || [type isEqualToString:@"FavoriteSubreddit"])) {
        ApolloLog(@"[SimDebugTap] shortcut rejected unknown type=%@", type ?: @"missing");
        return;
    }

    NSDictionary *userInfo = nil;
    if ([type isEqualToString:@"FavoriteSubreddit"]) {
        if (tokens.count < 2) {
            ApolloLog(@"[SimDebugTap] FavoriteSubreddit shortcut requires a subreddit");
            return;
        }
        userInfo = @{ @"subreddit": tokens[1] };
    }
    UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc]
        initWithType:type localizedTitle:type localizedSubtitle:nil icon:nil userInfo:userInfo];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        id delegate = scene.delegate;
        SEL selector = @selector(windowScene:performActionForShortcutItem:completionHandler:);
        if (![delegate respondsToSelector:selector]) continue;
        void (^completion)(BOOL) = ^(BOOL succeeded) {
            ApolloLog(@"[SimDebugTap] shortcut type=%@ completed=%d", type, succeeded);
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, selector, scene, item, completion);
        return;
    }
    ApolloLog(@"[SimDebugTap] shortcut: no scene delegate accepted the item");
}

static void ApolloSimDebugTapNotification(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *contents = [NSString stringWithContentsOfFile:kApolloSimTapFile
                                                       encoding:NSUTF8StringEncoding error:nil];
        if ([contents hasPrefix:@"insetbottom "]) {
            ApolloSimDebugForceBottomInset([[contents substringFromIndex:12] doubleValue]);
            return;
        }
        if ([contents hasPrefix:@"dump"]) {
            ApolloSimDebugDumpHierarchy();
            return;
        }
        // "compact on|off": force every split view controller under the tab bar
        // to a compact horizontal size class, which is what makes a
        // UISplitViewController collapse. Slide Over and small Stage Manager
        // windows are the real-world trigger and neither can be driven from a
        // script, so this is the only way to exercise the iPad pane layout's
        // collapse/expand path in the simulator loop.
        if ([contents hasPrefix:@"compact "]) {
            BOOL on = [[contents substringFromIndex:8] hasPrefix:@"on"];
            ApolloSimDebugForceCompactSplitColumns(on);
            return;
        }
        if ([contents hasPrefix:@"panemode "]) {
            NSString *mode = [[contents substringFromIndex:9]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugSetPaneMode(mode);
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"panestatus"]) {
            ApolloSimDebugLogPaneStatus();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"selectionstatus"]) {
            ApolloSimDebugLogMasterSelectionStatus();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"selectionclear"]) {
            ApolloSimDebugClearMasterSelection();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"selectioncontinue"]) {
            ApolloSimDebugPushSelectionContinuation();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"paneactivate showlist"]) {
            ApolloSimDebugActivateShowList();
            return;
        }
        if ([contents hasPrefix:@"navdump"]) {
            ApolloSimDebugDumpNavigationControllers();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"loadstatus"]) {
            ApolloSimDebugDumpPaneLoadStatus();
            return;
        }
        if ([contents hasPrefix:@"transitiongate "]) {
            NSString *operation = [[contents substringFromIndex:@"transitiongate ".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugSetTransitionGate(operation);
            return;
        }
        if ([contents hasPrefix:@"transitionselect "]) {
            NSString *identifier = [[contents substringFromIndex:@"transitionselect ".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugSelectTransitionProbe(identifier);
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"transitionstatus"]) {
            ApolloSimDebugDumpTransitionState();
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"transitionstale"]) {
            [ApolloPaneSplitViewController apollo_simRunDeallocatedSourceProbe];
            return;
        }
        if ([contents hasPrefix:@"transitionrace "]) {
            NSString *outcome = [[contents substringFromIndex:@"transitionrace ".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (![@[ @"commit", @"cancel" ] containsObject:outcome]) {
                ApolloLog(@"[SimDebugTap][transitionrace] expected commit|cancel, got %@", outcome);
                return;
            }
            ApolloSimDebugRunInteractiveTransitionRace([outcome isEqualToString:@"commit"]);
            return;
        }
        if ([contents hasPrefix:@"navitemdump"]) {
            NSString *columnName = [[contents substringFromIndex:@"navitemdump".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugDumpNavigationItem(columnName.length ? columnName : @"primary");
            return;
        }
        if ([contents hasPrefix:@"navitemprobe"]) {
            NSString *columnName = [[contents substringFromIndex:@"navitemprobe".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugProbeUnknownNavigationItem(columnName.length ? columnName : @"detail");
            return;
        }
        if ([contents hasPrefix:@"navitemmutate"]) {
            NSString *columnName = [[contents substringFromIndex:@"navitemmutate".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugMutateNavigationItem(columnName.length ? columnName : @"detail");
            return;
        }
        if ([contents hasPrefix:@"navback"]) {
            NSString *columnName = [[contents substringFromIndex:@"navback".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformNavigationBack(columnName.length ? columnName : @"primary");
            return;
        }
        if ([contents hasPrefix:@"navforward"]) {
            NSString *columnName = [[contents substringFromIndex:@"navforward".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformNavigationForward(columnName.length ? columnName : @"primary");
            return;
        }
        if ([contents hasPrefix:@"navset "]) {
            NSString *arguments = [[contents substringFromIndex:7]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugSetNavigationStack(arguments);
            return;
        }
        if ([[contents stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
                isEqualToString:@"accountchange"]) {
            ApolloSimDebugPostAccountContextChange();
            return;
        }
        if ([contents hasPrefix:@"tab "]) {
            ApolloSimDebugSelectTab([[contents substringFromIndex:4] integerValue]);
            return;
        }
        if ([contents hasPrefix:@"routeurl "]) {
            NSString *rawURL = [[contents substringFromIndex:9]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugRouteURL(rawURL);
            return;
        }
        if ([contents hasPrefix:@"useractivity "]) {
            NSString *rawURL = [[contents substringFromIndex:13]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugContinueUserActivity(rawURL);
            return;
        }
        if ([contents hasPrefix:@"shortcut "]) {
            NSString *arguments = [[contents substringFromIndex:9]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformShortcut(arguments);
            return;
        }
        if ([contents hasPrefix:@"accessibilityescape"]) {
            ApolloSimDebugPerformAccessibilityEscape();
            return;
        }
        if ([contents hasPrefix:@"visibleprobe "]) {
            NSString *operation = [[contents substringFromIndex:13]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugVisiblePresenterProbe(operation);
            return;
        }
        // "headerdump" command: log every visible scroll view's topEdgeEffect
        // state (pointer, hidden, style, tweak stamps) for header debugging.
        if ([contents hasPrefix:@"headerdump"]) {
            ApolloSimDebugDumpHeaderEffects();
            return;
        }
        // "headerstyle N" command: switch the Header Style setting through the
        // same path as the settings picker (global + persisted default +
        // change notification), so mode switches — including the live
        // install/remove machinery — can be driven from the host. simctl's
        // `defaults write` can't reach the app container's prefs domain.
        if ([contents hasPrefix:@"headerstyle "]) {
            NSInteger mode = [[contents substringFromIndex:12] integerValue];
            sScrollEdgeEffectStyle = mode;
            [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyScrollEdgeEffectStyle];
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloScrollEdgeEffectStyleChangedNotification object:nil];
            ApolloLog(@"[SimDebugTap] headerstyle -> %ld", (long)mode);
            return;
        }
        if ([contents hasPrefix:@"crash "]) {
            NSString *payload = [[contents substringFromIndex:6] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformCrash(payload);
            return;
        }
        if ([contents hasPrefix:@"insight "]) {
            NSString *fullName = [[contents substringFromIndex:8]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *username = ApolloActiveAccountUsername();
            ApolloFetchCommentVoteInsight(fullName, username,
                ^(ApolloCommentVoteInsight *insight, NSError *error) {
                    ApolloLog(@"[SimDebugTap] insight %@ ratio=%.1f upvotes=%lld error=%@",
                              fullName, insight.upvotePercent, insight.reportedUpvotes,
                              error.localizedDescription ?: @"none");
                });
            return;
        }
        if ([contents hasPrefix:@"text "]) {
            NSString *payload = [[contents substringFromIndex:5] stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            ApolloSimDebugTypeText(payload);
            return;
        }
        BOOL isSwipe = [contents hasPrefix:@"swipe "];
        BOOL isHold = [contents hasPrefix:@"hold "];
        BOOL isPress = [contents hasPrefix:@"press "];
        NSString *coordString = isSwipe ? [contents substringFromIndex:6]
                              : isHold  ? [contents substringFromIndex:5]
                              : isPress ? [contents substringFromIndex:6]
                                        : contents;
        NSArray<NSString *> *parts = [coordString componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray<NSString *> *numbers = [NSMutableArray array];
        for (NSString *part in parts) if (part.length > 0) [numbers addObject:part];
        if (isSwipe) {
            if (numbers.count < 4) { ApolloLog(@"[SimDebugTap] malformed swipe: %@", contents); return; }
            ApolloSimDebugPerformSwipe(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue),
                                       CGPointMake(numbers[2].doubleValue, numbers[3].doubleValue));
            return;
        }
        if (isHold) {
            if (numbers.count < 2) { ApolloLog(@"[SimDebugTap] malformed hold: %@", contents); return; }
            ApolloSimDebugPerformHold(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue));
            return;
        }
        if (isPress) {
            if (numbers.count < 2) { ApolloLog(@"[SimDebugTap] malformed press: %@", contents); return; }
            NSTimeInterval duration = numbers.count >= 3 ? numbers[2].doubleValue : 0.8;
            ApolloSimDebugPerformPress(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue),
                                       duration);
            return;
        }
        if (numbers.count < 2) {
            ApolloLog(@"[SimDebugTap] malformed tap file: %@", contents ?: @"(missing)");
            return;
        }
        ApolloSimDebugPerformTap(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue));
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        ApolloSimDebugTapNotification, CFSTR("apollofix.debugtap"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ApolloLog(@"[SimDebugTap] listening for apollofix.debugtap");
    ApolloLog(@"[CommentInsights][parser] self-tests %@",
              ApolloCommentVoteInsightsRunParserSelfTests() ? @"passed" : @"FAILED");
}

#endif
