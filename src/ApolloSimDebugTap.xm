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

#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
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
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIView *hitView = [window hitTest:point withEvent:nil];
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

// "dump" command: log geometry/inset state for every on-screen scroll view and
// tab bar, so inset regressions (e.g. issue #732) can be measured across
// app lifecycle transitions without any UI interaction.
static void ApolloSimDebugDumpScrollViews(UIView *view, int depth) {
    if (!view) return;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (sv.frame.size.height > 100) {
            UIEdgeInsets ci = sv.contentInset;
            UIEdgeInsets ai = sv.adjustedContentInset;
            UIEdgeInsets sa = sv.safeAreaInsets;
            ApolloLog(@"[SimDump] %@ frame=%@ offset=(%.1f,%.1f) contentH=%.1f inset(T%.1f B%.1f) adjusted(T%.1f B%.1f) safeArea(T%.1f B%.1f) adjBehavior=%ld vertBounce=%d",
                      NSStringFromClass(sv.class), NSStringFromCGRect(sv.frame),
                      sv.contentOffset.x, sv.contentOffset.y, sv.contentSize.height,
                      ci.top, ci.bottom, ai.top, ai.bottom, sa.top, sa.bottom,
                      (long)sv.contentInsetAdjustmentBehavior, sv.bounces);
        }
    }
    if ([view isKindOfClass:[UITabBar class]]) {
        ApolloLog(@"[SimDump] UITabBar frame=%@ hidden=%d alpha=%.2f superH=%.1f",
                  NSStringFromCGRect(view.frame), view.hidden, view.alpha,
                  view.superview.bounds.size.height);
    }
    for (UIView *sub in view.subviews) {
        ApolloSimDebugDumpScrollViews(sub, depth + 1);
    }
}

static void ApolloSimDebugPerformDump(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden) continue;
        ApolloLog(@"[SimDump] === window %@ ===", NSStringFromClass(window.class));
        ApolloSimDebugDumpScrollViews(window, 0);
        UIViewController *root = window.rootViewController;
        UIViewController *vc = root;
        while (vc && ![vc isKindOfClass:[UITabBarController class]]) {
            vc = vc.childViewControllers.firstObject;
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tbc = (UITabBarController *)vc;
            NSNumber *minBehavior = nil;
            SEL sel = NSSelectorFromString(@"tabBarMinimizeBehavior");
            if ([tbc respondsToSelector:sel]) {
                NSInteger v = ((NSInteger (*)(id, SEL))objc_msgSend)(tbc, sel);
                minBehavior = @(v);
            }
            NSNumber *minimized = nil;
            SEL minSel = NSSelectorFromString(@"isTabBarMinimized");
            if ([tbc respondsToSelector:minSel]) {
                minimized = @(((BOOL (*)(id, SEL))objc_msgSend)(tbc, minSel));
            }
            ApolloLog(@"[SimDump] TabBarController minimizeBehavior=%@ minimized=%@ safeArea(B%.1f)",
                      minBehavior ?: @"n/a", minimized ?: @"n/a",
                      tbc.view.safeAreaInsets.bottom);
        }
    }
    ApolloLog(@"[SimDump] === end ===");
}

// "fakesafe N" command: make every UIView's safeAreaInsets.bottom
// under-report by N points — emulating the iOS 27 device transient where a
// layout pass sees a bottom safe area that excludes the tab bar (issue
// #732) — then dirty all layout so Apollo's inset math reruns against the
// faked value. "fakesafe 0" restores reality. Sim-only test harness for
// ApolloListBottomInsetGuard.
//
// Manual swizzle rather than %hook: Logos emits hook-registration glue at
// the end of the file, OUTSIDE this #if APOLLO_SIM_BUILD region, which
// breaks device builds. The swizzle is installed lazily on first use.
static CGFloat sApolloSimFakeSafeAreaDeficit = 0.0;
static UIEdgeInsets (*sApolloSimOrigSafeAreaInsets)(id, SEL);

static UIEdgeInsets ApolloSimFakedSafeAreaInsets(id self, SEL _cmd) {
    UIEdgeInsets insets = sApolloSimOrigSafeAreaInsets(self, _cmd);
    if (sApolloSimFakeSafeAreaDeficit > 0.0) {
        insets.bottom = MAX(0.0, insets.bottom - sApolloSimFakeSafeAreaDeficit);
    }
    return insets;
}

static void ApolloSimInstallFakeSafeAreaHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getInstanceMethod([UIView class], @selector(safeAreaInsets));
        if (!method) return;
        sApolloSimOrigSafeAreaInsets = (UIEdgeInsets (*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)ApolloSimFakedSafeAreaInsets);
    });
}

static void ApolloSimDebugDirtyAllLayout(UIView *view) {
    [view setNeedsLayout];
    for (UIView *sub in view.subviews) {
        ApolloSimDebugDirtyAllLayout(sub);
    }
}

static void ApolloSimDebugTapNotification(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *contents = [NSString stringWithContentsOfFile:kApolloSimTapFile
                                                       encoding:NSUTF8StringEncoding error:nil];
        if ([contents hasPrefix:@"dump"]) {
            ApolloSimDebugPerformDump();
            return;
        }
        if ([contents hasPrefix:@"fakesafe "]) {
            ApolloSimInstallFakeSafeAreaHook();
            sApolloSimFakeSafeAreaDeficit = [[contents substringFromIndex:9] doubleValue];
            for (UIWindow *window in ApolloAllWindows()) {
                if (window.hidden) continue;
                ApolloSimDebugDirtyAllLayout(window);
                [window layoutIfNeeded];
            }
            ApolloLog(@"[SimDump] fakesafe deficit=%.1f applied + relayout forced",
                      sApolloSimFakeSafeAreaDeficit);
            return;
        }
        // "minbehavior N" command: set the main tab bar controller's
        // tabBarMinimizeBehavior (1=never → expands a minimized bar,
        // 2=onScrollDown) to emulate iOS 27's expand-on-foreground reset.
        if ([contents hasPrefix:@"minbehavior "]) {
            NSInteger value = [[contents substringFromIndex:12] integerValue];
            for (UIWindow *window in ApolloAllWindows()) {
                UIViewController *vc = window.rootViewController;
                while (vc && ![vc isKindOfClass:[UITabBarController class]]) {
                    vc = vc.childViewControllers.firstObject;
                }
                if (![vc isKindOfClass:[UITabBarController class]]) continue;
                SEL sel = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
                if ([vc respondsToSelector:sel]) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(vc, sel, value);
                    ApolloLog(@"[SimDump] set tabBarMinimizeBehavior=%ld", (long)value);
                }
                break;
            }
            return;
        }
        if ([contents hasPrefix:@"text "]) {
            NSString *payload = [[contents substringFromIndex:5] stringByTrimmingCharactersInSet:
                NSCharacterSet.newlineCharacterSet];
            ApolloSimDebugTypeText(payload);
            return;
        }
        BOOL isSwipe = [contents hasPrefix:@"swipe "];
        NSString *coordString = isSwipe ? [contents substringFromIndex:6] : contents;
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
}

#endif
