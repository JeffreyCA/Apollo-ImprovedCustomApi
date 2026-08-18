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
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloWebTextDecoding.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "UIWindow+Apollo.h"
#import <objc/message.h>

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
        // "linkpreview <url>" command: run the real link-preview fetch against
        // an arbitrary page and log what came back. Exercising the fetcher
        // needs no Reddit account, so metadata extraction — charset handling
        // above all (issue #945) — can be verified against live foreign-language
        // pages on a signed-out simulator.
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
    NSString *charsetFailure = nil;
    BOOL charsetOK = ApolloWebTextDecodingRunSelfTests(&charsetFailure);
    ApolloLog(@"[WebTextDecoding] self-tests %@", charsetOK ? @"passed"
              : [NSString stringWithFormat:@"FAILED at \"%@\"", charsetFailure]);
}

#endif
