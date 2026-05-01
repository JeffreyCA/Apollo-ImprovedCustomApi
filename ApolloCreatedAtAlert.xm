// ApolloCreatedAtAlert
//
// Tap a comment/post timestamp ("2.8y") to reveal an alert with the absolute
// creation date — mirrors Apollo's existing Edited-pencil alert.
//
// Wiring: the timestamp display nodes (CommentCellNode.ageNode,
// PostInfoNode.ageButtonNode) are layer-backed, so addTarget: and per-node
// gestures don't fire. We install one UITapGestureRecognizer on the cell's
// own view (always view-backed) and hit-test the embedded node's CALayer
// from shouldReceiveTouch:.
//
// Hooked cells: CommentCellNode (ageNode), CommentsHeaderCellNode /
// LargePostCellNode / CompactPostCellNode (postInfoNode.ageButtonNode).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"

// MARK: - AsyncDisplayKit minimal forward declarations

@interface ApolloASDisplayNode : UIResponder
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly, nullable) UIViewController *closestViewController;
@end

// MARK: - RDKCreated accessor

@interface RDKComment (ApolloCreatedAtAccessor)
@property (nonatomic, readonly) NSDate *createdUTC;
@end

// MARK: - Helpers

static const void *kApolloAgeTapGestureKey = &kApolloAgeTapGestureKey;
// Marker on our own gesture so the shared shouldReceiveTouch: can identify it.
static const void *kApolloAgeTapMarkerKey = &kApolloAgeTapMarkerKey;

static NSDateFormatter *ApolloAbsoluteDateFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        // Long date + short time matches Apollo's edited alert format.
        fmt.dateStyle = NSDateFormatterLongStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
    });
    return fmt;
}

static id ApolloIvarValueByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            return object_getIvar(obj, ivar);
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// Compact relative-time format matching Apollo's native ageNode/edited alert
// (s/m/h/d/mo with 1-decimal y). <5s short-circuits to "Just now".
static NSString *ApolloRelativeAgoString(NSDate *date) {
    if (!date) return nil;
    NSTimeInterval interval = fabs([date timeIntervalSinceNow]);
    if (interval < 5.0)       return @"Just now";
    if (interval < 60.0)      return [NSString stringWithFormat:@"%lds",  (long)interval];
    if (interval < 3600.0)    return [NSString stringWithFormat:@"%ldm",  (long)(interval / 60.0)];
    if (interval < 86400.0)   return [NSString stringWithFormat:@"%ldh",  (long)(interval / 3600.0)];
    if (interval < 2592000.0) return [NSString stringWithFormat:@"%ldd",  (long)(interval / 86400.0)];
    if (interval < 31536000.0) return [NSString stringWithFormat:@"%ldmo", (long)(interval / 2592000.0)];
    return [NSString stringWithFormat:@"%.1fy", interval / 31556736.0];
}

static UIViewController *ApolloPresenterForNode(ApolloASDisplayNode *node) {
    if (!node) return nil;

    // Texture's closestViewController walks supernode → UIResponder chain.
    UIViewController *vc = nil;
    if ([node respondsToSelector:@selector(closestViewController)]) {
        @try { vc = node.closestViewController; } @catch (__unused id e) {}
    }
    if (vc) return vc;

    UIView *view = nil;
    @try { view = node.view; } @catch (__unused id e) {}
    UIWindow *window = view.window;
    if (!window) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    return [window visibleViewController];
}

static void ApolloPresentCreatedAtAlert(NSDate *createdAt, ApolloASDisplayNode *anchor, BOOL isComment) {
    if (!createdAt || ![createdAt isKindOfClass:[NSDate class]]) return;
    UIViewController *presenter = ApolloPresenterForNode(anchor);
    if (!presenter) return;

    NSString *verb = isComment ? @"Commented" : @"Posted";
    NSString *relative = ApolloRelativeAgoString(createdAt) ?: @"Just now";
    NSString *title;
    if ([relative isEqualToString:@"Just now"]) {
        title = [NSString stringWithFormat:@"%@ %@", verb, relative];
    } else {
        title = [NSString stringWithFormat:@"%@ %@ Ago", verb, relative];
    }

    NSString *message = nil;
    if (fabs([createdAt timeIntervalSinceNow]) >= 5.0) {
        message = [NSString stringWithFormat:@"%@ on %@", verb,
                                              [ApolloAbsoluteDateFormatter() stringFromDate:createdAt]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// YES if `touch` falls inside `targetNode`'s layer (in containerView coords),
// padded for comfortable touch targets. Works for layer-backed nodes too.
static BOOL ApolloTouchHitsNode(ApolloASDisplayNode *targetNode, UIView *containerView, UITouch *touch) {
    if (!targetNode || targetNode.isHidden || !containerView || !touch) return NO;

    CALayer *targetLayer = nil;
    @try { targetLayer = targetNode.layer; } @catch (__unused id e) {}
    if (!targetLayer || !containerView.layer) return NO;

    CGRect rect = [targetLayer convertRect:targetLayer.bounds toLayer:containerView.layer];
    if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || CGRectIsInfinite(rect)) return NO;

    rect = CGRectInset(rect, -10.0, -8.0);
    CGPoint pt = [touch locationInView:containerView];
    return CGRectContainsPoint(rect, pt);
}

// Resolves the timestamp node for a cell. Comment cells expose ageNode
// directly; post-style cells embed PostInfoNode which holds ageButtonNode.
static ApolloASDisplayNode *ApolloAgeDisplayNodeForCell(id cell) {
    if (!cell) return nil;

    ApolloASDisplayNode *direct = ApolloIvarValueByName(cell, "ageNode");
    if (direct) return direct;

    id postInfoNode = ApolloIvarValueByName(cell, "postInfoNode");
    if (postInfoNode) {
        ApolloASDisplayNode *ageButtonNode = ApolloIvarValueByName(postInfoNode, "ageButtonNode");
        if (ageButtonNode) return ageButtonNode;
    }
    return nil;
}

// Idempotent.
static void ApolloInstallAgeTapOnCell(id cell, SEL handler) {
    if (!cell) return;
    if (objc_getAssociatedObject(cell, kApolloAgeTapGestureKey)) return;

    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:cell action:handler];
    tap.cancelsTouchesInView = YES;
    tap.delegate = (id<UIGestureRecognizerDelegate>)cell;
    objc_setAssociatedObject(tap, kApolloAgeTapMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloAgeTapGestureKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cellView addGestureRecognizer:tap];
}

// Only acts on our own gesture; defers to other delegate-routed gestures.
static BOOL ApolloAgeTapShouldReceiveTouch(id cell, UIGestureRecognizer *gr, UITouch *touch) {
    if (!objc_getAssociatedObject(gr, kApolloAgeTapMarkerKey)) return YES;

    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    ApolloASDisplayNode *ageNode = ApolloAgeDisplayNodeForCell(cell);
    return ApolloTouchHitsNode(ageNode, cellView, touch);
}

static void ApolloAgeTapFired(id cell, UITapGestureRecognizer *tap) {
    if (tap.state != UIGestureRecognizerStateRecognized) return;

    // Comment cells carry an RDKComment; everything else is a post (RDKLink).
    RDKComment *comment = ApolloIvarValueByName(cell, "comment");
    NSDate *date = nil;
    BOOL isComment = NO;
    if (comment) {
        NSDate *d = comment.createdUTC;
        if ([d isKindOfClass:[NSDate class]]) {
            date = d;
            isComment = YES;
        }
    }
    if (!date) {
        RDKLink *link = ApolloIvarValueByName(cell, "link");
        NSDate *d = link.createdUTC;
        if ([d isKindOfClass:[NSDate class]]) date = d;
    }
    if (!date) return;

    ApolloPresentCreatedAtAlert(date, (ApolloASDisplayNode *)cell, isComment);
}

// MARK: - Hooks

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    ApolloInstallAgeTapOnCell(self, @selector(apollo_ageTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloAgeTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_ageTapFired:(UITapGestureRecognizer *)tap {
    ApolloAgeTapFired(self, tap);
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApolloInstallAgeTapOnCell(self, @selector(apollo_ageTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloAgeTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_ageTapFired:(UITapGestureRecognizer *)tap {
    ApolloAgeTapFired(self, tap);
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloInstallAgeTapOnCell(self, @selector(apollo_ageTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloAgeTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_ageTapFired:(UITapGestureRecognizer *)tap {
    ApolloAgeTapFired(self, tap);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloInstallAgeTapOnCell(self, @selector(apollo_ageTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloAgeTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_ageTapFired:(UITapGestureRecognizer *)tap {
    ApolloAgeTapFired(self, tap);
}

%end
