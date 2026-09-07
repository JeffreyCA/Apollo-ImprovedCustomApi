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
#import "ApolloFloatingTabs.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloTranslation.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloWebTextDecoding.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "UIWindow+Apollo.h"

void ApolloSubredditIndexDebugDescribeTables(void); // ApolloSubredditIndexPolish.xm (sim-only)
#import <objc/message.h>
#import <mach/mach.h>

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
// steps/interval control the drag speed: the default 12 x 12 ms is a flick that
// commits an interactive pop; a slow, short drag (e.g. 30 x 20 ms to x=45) ends
// below UIKit's commit threshold and cancels it instead.
static void ApolloSimDebugPerformSwipeTimed(CGPoint start, CGPoint end, int steps, NSTimeInterval interval) {
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

    for (int i = 1; i <= steps; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CGFloat t = (CGFloat)i / steps;
            CGPoint p = CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
            [touch _setLocationInWindow:p resetPrevious:NO];
            [touch setPhase:UITouchPhaseMoved];
            ApolloSimDebugSendTouch(touch);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((steps * interval + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch _setLocationInWindow:end resetPrevious:NO];
        [touch setPhase:UITouchPhaseEnded];
        ApolloSimDebugSendTouch(touch);
        ApolloLog(@"[SimDebugTap] swipe delivered (%.0f,%.0f)->(%.0f,%.0f) over %d x %.0f ms",
                  start.x, start.y, end.x, end.y, steps, interval * 1000.0);
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
void ApolloSubredditListDiagRearm(void);

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

#pragma mark - gifmem probe (issue #1000)

static double ApolloSimDebugFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1.0;
    return info.phys_footprint / 1048576.0;
}

// Keeps the probe's view + image alive between samples.
static UIImageView *sApolloSimDebugGIFView = nil;
static UIImage *sApolloSimDebugGIFImage = nil;

static void ApolloSimDebugSampleGIFMemory(NSInteger remaining, double baseline) {
    ApolloLog(@"[gifmem] t+%lds footprint %.0f MB (+%.0f)",
              (long)(6 - remaining), ApolloSimDebugFootprintMB(), ApolloSimDebugFootprintMB() - baseline);
    if (remaining <= 0) {
        [sApolloSimDebugGIFView removeFromSuperview];
        sApolloSimDebugGIFView = nil;
        sApolloSimDebugGIFImage = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloLog(@"[gifmem] released: footprint %.0f MB (+%.0f)",
                      ApolloSimDebugFootprintMB(), ApolloSimDebugFootprintMB() - baseline);
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSimDebugSampleGIFMemory(remaining - 1, baseline);
    });
}

static void ApolloSimDebugMeasureGIFMemory(NSString *source) {
    double baseline = ApolloSimDebugFootprintMB();
    ApolloLog(@"[gifmem] baseline footprint %.0f MB, source %@", baseline, source);

    void (^measure)(NSData *) = ^(NSData *data) {
        if (data.length == 0) { ApolloLog(@"[gifmem] no bytes"); return; }
        ApolloLog(@"[gifmem] %.1f MB of source bytes", data.length / 1048576.0);

        UIWindow *window = nil;
        for (UIWindow *candidate in ApolloAllWindows()) if (candidate.isKeyWindow) { window = candidate; break; }
        window = window ?: ApolloAllWindows().firstObject;
        if (!window) { ApolloLog(@"[gifmem] no window"); return; }

        NSDate *start = NSDate.date;
        ApolloGalleryDecodedImage *decoded = [ApolloGalleryImageLoader apollo_debugDecodeData:data];
        if (!decoded) { ApolloLog(@"[gifmem] decode returned nil"); return; }
        ApolloLog(@"[gifmem] decoded %.0fx%.0f in %.2fs, animated=%@",
                  decoded.image.size.width, decoded.image.size.height,
                  -[start timeIntervalSinceNow], decoded.animatedImage ? @"YES" : @"NO");

        // Mounted exactly the way a viewer page mounts it, so the sample covers
        // the frame traffic UIKit generates during playback and not just the
        // decode.
        Class viewClass = NSClassFromString(@"FLAnimatedImageView") ?: UIImageView.class;
        UIImageView *view = [[viewClass alloc] initWithFrame:window.bounds];
        if (decoded.animatedImage && [view respondsToSelector:@selector(setAnimatedImage:)]) {
            [view setValue:decoded.animatedImage forKey:@"animatedImage"];
        } else {
            view.image = decoded.image;
        }
        sApolloSimDebugGIFImage = decoded.image;
        double afterDecode = ApolloSimDebugFootprintMB();
        ApolloLog(@"[gifmem] after build: footprint %.0f MB (+%.0f)", afterDecode, afterDecode - baseline);

        view.contentMode = UIViewContentModeScaleAspectFit;
        [window addSubview:view];
        sApolloSimDebugGIFView = view;
        ApolloLog(@"[gifmem] installed on screen, sampling for 6s…");
        ApolloSimDebugSampleGIFMemory(6, baseline);
    };

    if ([source hasPrefix:@"http"]) {
        NSURL *url = [NSURL URLWithString:source];
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ measure(data); });
        }] resume];
    } else {
        measure([NSData dataWithContentsOfFile:source]);
    }
}

// "navchurn" command: pop the top controller and push it straight back in the
// same turn. UIKit queues the push and starts it synchronously from inside the
// pop's completeTransition: (the same shape as a push issued from
// didShowViewController:, which nickclyde raised on #1018), so two transitions
// overlap on the stack and ApolloInterruptibleNavTransition must hand each its
// own animator. 1.5 s later this logs what the pair left behind: the stack, the
// interaction flags UIKit/our completion should have restored, the interactive
// in-flight counter, and every sibling of the top view in the transition
// container (a leftover dim/shadow view shows up there as a plain UIView).
static UINavigationController *ApolloSimDebugNavChurnNavigationController(void) {
    UIViewController *vc = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) { vc = window.rootViewController; break; }
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UITabBarController.class]) vc = ((UITabBarController *)vc).selectedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) return (UINavigationController *)vc;
    return vc.navigationController;
}

static void ApolloSimDebugNavChurnReport(UINavigationController *nav, NSString *phase) {
    UIViewController *top = nav.topViewController;
    UIViewController *below = nav.viewControllers.count >= 2
        ? nav.viewControllers[nav.viewControllers.count - 2] : nil;
    NSMutableArray<NSString *> *siblings = [NSMutableArray array];
    for (UIView *view in top.view.superview.subviews) {
        [siblings addObject:[NSString stringWithFormat:@"%@%@%@", NSStringFromClass(view.class),
            view.accessibilityIdentifier ? [@"#" stringByAppendingString:view.accessibilityIdentifier] : @"",
            view == top.view ? @"(top)" : @""]];
    }
    ApolloLog(@"[SimDebugTap] navchurn %@: stack=%lu top=%@ topInteractive=%d belowInteractive=%d "
              "inFlight=%d containerSubviews=[%@]",
              phase, (unsigned long)nav.viewControllers.count, NSStringFromClass(top.class),
              top.view.userInteractionEnabled, below.view.userInteractionEnabled,
              ApolloNavTransitionInFlight(), [siblings componentsJoinedByString:@", "]);
}

// "navchurn appear" variant: the push is issued from the revealed controller's
// viewDidAppear:, which UIKit runs inside the pop's completeTransition:, so the
// pop's completion block is still on the stack when the push is requested.
static __weak UIViewController *sApolloSimNavChurnRevealed;
static __weak UIViewController *sApolloSimNavChurnPopped;

static void ApolloSimDebugNavChurn(NSString *mode) {
    UINavigationController *nav = ApolloSimDebugNavChurnNavigationController();
    if ([mode isEqualToString:@"report"] && nav) {
        ApolloSimDebugNavChurnReport(nav, @"report");
        return;
    }
    if (!nav || nav.viewControllers.count < 2) {
        ApolloLog(@"[SimDebugTap] navchurn: needs a pushed controller (nav=%@ depth=%lu)",
                  nav, (unsigned long)nav.viewControllers.count);
        return;
    }
    ApolloSimDebugNavChurnReport(nav, @"before");
    UIViewController *top = nav.topViewController;
    if ([mode isEqualToString:@"appear"]) {
        sApolloSimNavChurnRevealed = nav.viewControllers[nav.viewControllers.count - 2];
        sApolloSimNavChurnPopped = top;
        ApolloLog(@"[SimDebugTap] navchurn appear: pop %@, push it back from %@'s viewDidAppear:",
                  NSStringFromClass(top.class), NSStringFromClass(sApolloSimNavChurnRevealed.class));
        [nav popViewControllerAnimated:YES];
    } else {
        ApolloLog(@"[SimDebugTap] navchurn: pop %@ and push it back in the same turn",
                  NSStringFromClass(top.class));
        [nav popViewControllerAnimated:YES];
        [nav pushViewController:top animated:YES];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloSimDebugNavChurnReport(nav, @"after");
    });
}

// Grouped on purpose: an ungrouped %hook makes Logos append its registration
// after the closing #endif, where the device build (no APOLLO_SIM_BUILD) has
// none of these declarations. %init(ApolloSimNavChurn) lives in the %ctor below.
%group ApolloSimNavChurn
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *popped = sApolloSimNavChurnPopped;
    if (!popped || self != sApolloSimNavChurnRevealed) return;
    sApolloSimNavChurnRevealed = nil;
    sApolloSimNavChurnPopped = nil;
    UINavigationController *nav = self.navigationController;
    [nav pushViewController:popped animated:YES];
    ApolloLog(@"[SimDebugTap] navchurn appear: pushed %@ from viewDidAppear:; coordinator now %@ "
              "(non-nil means the push started synchronously, inside the pop's completeTransition:)",
              NSStringFromClass(popped.class), nav.transitionCoordinator);
}
%end
%end

// "scrollto Y" command support: pin the tallest on-screen scroll view (the
// comments table on a thread) to a content offset, so a test can land on the
// same comments every run — a synthesized flick's inertia varies run to run.
static UIScrollView *ApolloSimDebugTallestScrollViewIn(UIView *view) {
    UIScrollView *best = nil;
    if ([view isKindOfClass:[UIScrollView class]] && !view.hidden && view.window) {
        best = (UIScrollView *)view;
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *candidate = ApolloSimDebugTallestScrollViewIn(sub);
        if (candidate && (!best || candidate.contentSize.height > best.contentSize.height)) {
            best = candidate;
        }
    }
    return best;
}

static void ApolloSimDebugScrollTo(CGFloat y) {
    UIScrollView *best = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden) continue;
        UIScrollView *candidate = ApolloSimDebugTallestScrollViewIn(window);
        if (candidate && (!best || candidate.contentSize.height > best.contentSize.height)) {
            best = candidate;
        }
    }
    if (!best) { ApolloLog(@"[SimDebugTap] scrollto: no scroll view"); return; }
    CGFloat top = best.adjustedContentInset.top;
    CGFloat maxY = MAX(-top, best.contentSize.height - best.bounds.size.height + best.adjustedContentInset.bottom);
    CGFloat target = MIN(MAX(y - top, -top), maxY);
    [best setContentOffset:CGPointMake(best.contentOffset.x, target) animated:NO];
    ApolloLog(@"[SimDebugTap] scrollto %.0f -> offset %.0f (%@ content %.0f)",
              y, target, NSStringFromClass([best class]), best.contentSize.height);
}

// "lpm on|off" command support: the simulator has no Battery settings pane,
// so Low Power Mode can't be toggled there. Force -[NSProcessInfo
// isLowPowerModeEnabled] instead and post the real power-state notification,
// so the inline-GIF autoplay rules (which must ignore LPM — #634/#1004) and
// anything else listening to the power state react exactly as on a device.
// Swizzled by hand on the CONCRETE class of +[NSProcessInfo processInfo]
// (swift-foundation hands back an _NSSwiftProcessInfo subclass on current
// iOS, so a plain `%hook NSProcessInfo` never sees the call).
static BOOL sApolloSimForceLowPowerMode = NO;
static BOOL (*sApolloSimOrigIsLowPowerModeEnabled)(id, SEL) = NULL;

static BOOL ApolloSimHookedIsLowPowerModeEnabled(id self, SEL _cmd) {
    if (sApolloSimForceLowPowerMode) return YES;
    return sApolloSimOrigIsLowPowerModeEnabled ? sApolloSimOrigIsLowPowerModeEnabled(self, _cmd) : NO;
}

static void ApolloSimInstallLowPowerModeOverride(void) {
    Class cls = object_getClass(NSProcessInfo.processInfo);
    Method m = class_getInstanceMethod(cls, @selector(isLowPowerModeEnabled));
    if (!m) {
        ApolloLog(@"[SimDebugTap] lpm override: no isLowPowerModeEnabled on %@", NSStringFromClass(cls));
        return;
    }
    sApolloSimOrigIsLowPowerModeEnabled = (BOOL (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)ApolloSimHookedIsLowPowerModeEnabled);
    ApolloLog(@"[SimDebugTap] lpm override installed on %@", NSStringFromClass(cls));
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
        // "headerdump" command: log every visible scroll view's topEdgeEffect
        // state (pointer, hidden, style, tweak stamps) for header debugging.
        if ([contents hasPrefix:@"headerdump"]) {
            ApolloSimDebugDumpHeaderEffects();
            return;
        }
        // "listdiag" command: re-arm the subreddit-list launch geometry
        // recorder (ApolloSubredditListLaunchSettle) against the list
        // controller, so the settle can be observed on a pop-back without a
        // cold launch.
        if ([contents hasPrefix:@"listdiag"]) {
            ApolloSubredditListDiagRearm();
            return;
        }
        // "indexdiag" command: log every known subreddit table's section-index
        // state (native index color, captured native state, overlay) — see
        // ApolloSubredditIndexDebugDescribeTables in ApolloSubredditIndexPolish.
        if ([contents hasPrefix:@"indexdiag"]) {
            ApolloSubredditIndexDebugDescribeTables();
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
        // "gifmode N" command: set Autoplay Inline GIFs (1 Never, 2 WiFi Only,
        // 3 Always, 4 Tap to Play) through the same defaults write the settings
        // picker makes, so the KVO reload + live refresh of on-screen GIFs run.
        if ([contents hasPrefix:@"gifmode "]) {
            NSInteger mode = [[contents substringFromIndex:8] integerValue];
            [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyAutoplayInlineGIFs];
            ApolloLog(@"[SimDebugTap] gifmode -> %ld", (long)mode);
            return;
        }
        if ([contents hasPrefix:@"scrollto "]) {
            ApolloSimDebugScrollTo([[contents substringFromIndex:9] doubleValue]);
            return;
        }
        if ([contents hasPrefix:@"lpm "]) {
            NSString *payload = [[contents substringFromIndex:4] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            sApolloSimForceLowPowerMode = [payload isEqualToString:@"on"];
            [[NSNotificationCenter defaultCenter] postNotificationName:NSProcessInfoPowerStateDidChangeNotification
                                                                object:NSProcessInfo.processInfo];
            ApolloLog(@"[SimDebugTap] lpm -> %d (isLowPowerModeEnabled=%d)",
                      sApolloSimForceLowPowerMode, NSProcessInfo.processInfo.isLowPowerModeEnabled);
            return;
        }
        if ([contents hasPrefix:@"crash "]) {
            NSString *payload = [[contents substringFromIndex:6] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugPerformCrash(payload);
            return;
        }
        if ([contents hasPrefix:@"navchurn"]) {
            NSString *mode = [[contents substringFromIndex:8] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugNavChurn(mode);
            return;
        }
        // "devvitjs <js>" command: evaluate JS in the live interactive-post
        // widget's web view and log the result (DOM inspection without a web
        // inspector). See ApolloDevvitDebugEvaluateJS in ApolloDevvitPosts.xm.
        if ([contents hasPrefix:@"devvitjs "]) {
            extern void ApolloDevvitDebugEvaluateJS(NSString *js);
            ApolloDevvitDebugEvaluateJS([contents substringFromIndex:9]);
            return;
        }
        // "chatjs <js>" command: evaluate JS in the most recently created
        // modern Chat/Modmail web view (the Inbox hub's, normally) and log
        // the result. Lets a sim reproduce web-side states the sim's own
        // WebKit never produces — e.g. `chatjs history.replaceState(null,"",
        // "/chat")` inside a room mimics the device's room-under-a-list-URL
        // desync. See ApolloDirectChatDebugEvaluateJS in ApolloDirectChatWeb.xm.
        if ([contents hasPrefix:@"chatjs "]) {
            extern void ApolloDirectChatDebugEvaluateJS(NSString *js);
            ApolloDirectChatDebugEvaluateJS([contents substringFromIndex:7]);
            return;
        }
        // "devvitsweep": run the interactive-post stale-width sweep now, with
        // a per-surface geometry dump.
        if ([contents hasPrefix:@"devvitsweep"]) {
            extern void ApolloDevvitDebugSweep(void);
            ApolloDevvitDebugSweep();
            return;
        }
        // "rotate <landscape|portrait>" command: rotate the scene from inside
        // the app — Simulator.app menu automation needs accessibility grants a
        // headless agent doesn't have, and simctl has no rotate.
        if ([contents hasPrefix:@"rotate "]) {
            NSString *dir = [[contents substringFromIndex:7] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (@available(iOS 16.0, *)) {
                UIInterfaceOrientationMask mask = [dir isEqualToString:@"landscape"]
                    ? UIInterfaceOrientationMaskLandscapeRight
                    : UIInterfaceOrientationMaskPortrait;
                UIWindowScene *scene = ApolloAllWindows().firstObject.windowScene;
                if (!scene) { ApolloLog(@"[SimDebugTap] rotate: no window scene"); return; }
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
                [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                    ApolloLog(@"[SimDebugTap] rotate error: %@", error.localizedDescription);
                }];
                ApolloLog(@"[SimDebugTap] rotate -> %@", dir);
            } else {
                ApolloLog(@"[SimDebugTap] rotate: needs iOS 16+");
            }
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
        // "linkpreview <url>" command: run the real link-preview fetch against
        // an arbitrary page and log what came back. Exercising the fetcher
        // needs no Reddit account, so metadata extraction — charset handling
        // above all (issue #945) — can be verified against live foreign-language
        // pages on a signed-out simulator.
        // "gifmem <path-or-url>" command: measure what the gallery viewer's
        // animated-GIF path actually costs in resident memory. Decodes with the
        // shipping loader entry point, hangs the result on a real on-screen
        // UIImageView, and samples phys_footprint across the first animation
        // loops — the point where issue #1000's jetsam happened.
        if ([contents hasPrefix:@"gifmem "]) {
            NSString *arg = [[contents substringFromIndex:7] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloSimDebugMeasureGIFMemory(arg);
            return;
        }
        if ([contents hasPrefix:@"linkpreview "]) {
            NSString *urlString = [[contents substringFromIndex:12] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURL *previewURL = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
            if (!previewURL) { ApolloLog(@"[SimDebugTap] malformed linkpreview url: %@", urlString); return; }
            [ApolloLinkPreviewFetcher requestPreviewForURL:previewURL completion:^(ApolloLinkPreview *preview) {
                ApolloLog(@"[SimDebugTap] linkpreview %@\n  site=%@\n  title=%@\n  desc=%@\n  image=%@",
                          urlString, preview.siteName ?: @"(nil)", preview.title ?: @"(nil)",
                          preview.desc ?: @"(nil)", preview.imageURL.absoluteString ?: @"(nil)");
            }];
            return;
        }
        // "translate <google|libre|auto> <text>" command: run text through the
        // real translation provider pipeline and log the result. Needs no
        // Reddit session — isolates provider/network failures (issue #995).
        if ([contents hasPrefix:@"translate "]) {
            NSString *spec = [[contents substringFromIndex:10] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloTranslationDebugProbe(spec);
            return;
        }
        if ([contents hasPrefix:@"text "]) {
            NSString *payload = [[contents substringFromIndex:5] stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            ApolloSimDebugTypeText(payload);
            return;
        }
        // "floattab <keep|state|tap N|close N|release N cx cy vx vy>": drive
        // the Floating Post Tabs feature headlessly (create a tab from the
        // topmost comments view, tap/close bubbles, run the real end-of-drag
        // pipeline for magnet/tuck/dock testing, dump tab state to the log).
        if ([contents hasPrefix:@"floattab "]) {
            NSString *payload = [[contents substringFromIndex:9] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            ApolloFloatingTabsDebugCommand(payload);
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
            // Optional 5th/6th numbers: step count and per-step interval in seconds.
            int steps = numbers.count >= 5 ? MAX(1, numbers[4].intValue) : 12;
            NSTimeInterval interval = numbers.count >= 6 ? MAX(0.001, numbers[5].doubleValue) : 0.012;
            ApolloSimDebugPerformSwipeTimed(CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue),
                                            CGPointMake(numbers[2].doubleValue, numbers[3].doubleValue),
                                            steps, interval);
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
    %init(ApolloSimNavChurn);
    ApolloSimInstallLowPowerModeOverride();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        ApolloSimDebugTapNotification, CFSTR("apollofix.debugtap"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    ApolloLog(@"[SimDebugTap] listening for apollofix.debugtap");
    ApolloLog(@"[CommentInsights][parser] self-tests %@",
              ApolloCommentVoteInsightsRunParserSelfTests() ? @"passed" : @"FAILED");
    NSString *charsetFailure = nil;
    BOOL charsetOK = ApolloWebTextDecodingRunSelfTests(&charsetFailure);
    ApolloLog(@"[WebTextDecoding] self-tests %@", charsetOK ? @"passed"
              : [NSString stringWithFormat:@"FAILED at \"%@\"", charsetFailure]);
}

#endif
