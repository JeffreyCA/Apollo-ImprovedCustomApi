// ApolloVideoHoldSpeed.xm
//
// "Hold for 2×" — press-and-hold the RIGHT third of the fullscreen video to
// play it at 2× speed while held; release to restore the previous rate.
// (GitHub issue #78.)
//
// The fullscreen player is `MediaViewerController` (ObjC name
// `_TtC6Apollo21MediaViewerController`). A long-press anywhere on it normally
// brings up the Share Link / Download Video / Playback Speed context menu
// (driven by one of several UILongPressGestureRecognizers in its view tree).
//
// We must coexist with that menu, not replace it:
//
//     ┌──────────────────────────┬──────────┐
//     │     left + center 2/3    │  right ⅓ │
//     │   normal long-press menu │  2× hold │
//     └──────────────────────────┴──────────┘
//
// Why a custom passive recognizer (not a UILongPressGestureRecognizer):
//   A second long-press recognizer competing with Apollo's loses UIKit's gesture
//   arbitration — it reaches the "should begin?" point but is then failed by the
//   menu recognizer before it commits to .began, so its action never fires
//   (verified in the logs). Instead we attach a custom UIGestureRecognizer that
//   never "recognizes" — it stays in .possible and just observes raw touches, so
//   arbitration can't kill it and it never blocks Apollo's own tap/pan handling.
//
// Mechanics:
//   • On touch-DOWN we check, against the video's live on-screen geometry, whether
//     the touch is in the right third. If so we immediately DISABLE every other
//     long-press recognizer in the tree — so the menu simply can't appear for this
//     touch — and re-enable them on release. (No timing race with the menu.)
//   • If the press is still held after a short delay, we capture the live rate,
//     force 2×, and show a "2× ⏵⏵" overlay. On release we restore the captured
//     rate and hide the overlay. A quick tap in the right zone just toggles the
//     menu recognizers off/on with no speed change.
//   • Left/center touches are left entirely alone, so the normal menu still works.
//   • We never touch `videoPlaybackSpeed` (Apollo's persistent menu choice), so
//     the speed menu's checkmark stays correct.
//
// Orientation: the right-third test projects the touch onto the video's displayed
// left→right axis, so it stays correct when Apollo transform-rotates the content
// to landscape on the portrait-locked screen, and under pinch-zoom.

#import "ApolloCommon.h"

#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Rightmost fraction of the video that activates hold-to-2×.
static const CGFloat kRightZoneFraction = 1.0 / 3.0;

// The speed applied while held.
static const float kHoldSpeed = 2.0f;

// How long the press must be held before 2× engages. Short enough to feel
// instant, long enough that a quick tap never trips it. (This only gates the
// speed change — the menu is suppressed at touch-down, so there's no race.)
static const NSTimeInterval kHoldActivationDelay = 0.18;

// Movement (in points) that cancels a pending hold, so a drag becomes a normal
// scrub / swipe-to-dismiss instead of a speed-up.
static const CGFloat kHoldMoveTolerance = 12.0;

#pragma mark - Player access (mirrors ApolloVideoPlaybackSpeed.xm)

static AVPlayer *PlayerFromLayer(CALayer *layer) {
    if (!layer) return nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayer *p = [(AVPlayerLayer *)layer player];
        if (p) return p;
    }
    for (CALayer *sub in layer.sublayers) {
        AVPlayer *p = PlayerFromLayer(sub);
        if (p) return p;
    }
    return nil;
}

static AVPlayer *PlayerFromView(UIView *view) {
    if (!view) return nil;
    SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
    if ([view respondsToSelector:playerLayerSel]) {
        id pl = ((id (*)(id, SEL))objc_msgSend)(view, playerLayerSel);
        if ([pl isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayer *p = [(AVPlayerLayer *)pl player];
            if (p) return p;
        }
    }
    AVPlayer *p = PlayerFromLayer(view.layer);
    if (p) return p;
    for (UIView *sub in view.subviews) {
        p = PlayerFromView(sub);
        if (p) return p;
    }
    return nil;
}

// MediaViewerController stores its AVPlayer two ways: directly on the `player`
// ivar for non-shareable videos (GIFs/Streamable), or — for shareable v.redd.it
// videos — on the `playerLayerContainerView`'s AVPlayerLayer (the `player` ivar
// is nil). Mirror Apollo's own lookup, with a view-tree scan as a last resort.
static AVPlayer *MediaViewerPlayer(UIViewController *mvc) {
    if (!mvc) return nil;

    Ivar playerIvar = class_getInstanceVariable([mvc class], "player");
    if (playerIvar) {
        id player = object_getIvar(mvc, playerIvar);
        if ([player isKindOfClass:[AVPlayer class]]) return (AVPlayer *)player;
    }

    Ivar containerIvar = class_getInstanceVariable([mvc class], "playerLayerContainerView");
    if (containerIvar) {
        id container = object_getIvar(mvc, containerIvar);
        if ([container isKindOfClass:[UIView class]]) {
            AVPlayer *p = PlayerFromView((UIView *)container);
            if (p) return p;
        }
    }

    return PlayerFromView(mvc.isViewLoaded ? mvc.view : nil);
}

// The view whose bounds the video fills. In fullscreen this is the view Apollo
// rotates (via a transform) to show landscape video on the portrait-locked
// screen, so its on-screen geometry tells us where the video's edges actually
// are in the CURRENT orientation. Used for orientation-correct zone detection.
static BOOL LayerHostsPlayer(CALayer *layer) {
    if ([layer isKindOfClass:[AVPlayerLayer class]]) return YES;
    for (CALayer *s in layer.sublayers) {     // shallow: immediate sublayers only
        if ([s isKindOfClass:[AVPlayerLayer class]]) return YES;
    }
    return NO;
}

static UIView *DeepestViewHostingPlayer(UIView *view) {
    if (!view) return nil;
    for (UIView *sub in view.subviews) {
        UIView *deep = DeepestViewHostingPlayer(sub);
        if (deep) return deep;
    }
    return LayerHostsPlayer(view.layer) ? view : nil;
}

static UIView *MediaVideoView(UIViewController *mvc) {
    if (!mvc) return nil;
    Ivar containerIvar = class_getInstanceVariable([mvc class], "playerLayerContainerView");
    if (containerIvar) {
        id c = object_getIvar(mvc, containerIvar);
        if ([c isKindOfClass:[UIView class]]) return (UIView *)c;
    }
    UIView *host = DeepestViewHostingPlayer(mvc.isViewLoaded ? mvc.view : nil);
    return host ?: (mvc.isViewLoaded ? mvc.view : nil);
}

// Collect every UIContextMenuInteraction in a view subtree, with the view that
// owns each (a UIInteraction's `view` is nilled once removed, so we must capture
// it up front to re-add later). The Share/Download/Speed menu is driven by one
// of these; removing it for the duration of a right-zone hold is what suppresses
// the menu — its internal trigger isn't a plain UILongPressGestureRecognizer, so
// disabling recognizers by class doesn't reach it.
static void CollectContextMenuInteractions(UIView *view,
                                           NSMutableArray<UIView *> *outViews,
                                           NSMutableArray<UIContextMenuInteraction *> *outInteractions) {
    if (!view) return;
    for (id<UIInteraction> it in view.interactions) {
        if ([it isKindOfClass:[UIContextMenuInteraction class]]) {
            [outViews addObject:view];
            [outInteractions addObject:(UIContextMenuInteraction *)it];
        }
    }
    for (UIView *sub in view.subviews) {
        CollectContextMenuInteractions(sub, outViews, outInteractions);
    }
}

#pragma mark - Passive touch recognizer

// A gesture recognizer that never recognizes — it stays in .possible and only
// reports the raw touch lifecycle, so UIKit's gesture arbitration never fails it
// and it never blocks Apollo's own recognizers.
@interface ApolloHoldTouchRecognizer : UIGestureRecognizer
@property (nonatomic, copy) void (^onTouchDown)(CGPoint windowPoint);
@property (nonatomic, copy) void (^onHoldElapsed)(CGPoint windowPoint);
@property (nonatomic, copy) void (^onTouchUp)(void);
@end

@implementation ApolloHoldTouchRecognizer {
    BOOL _armed;          // tracking a single touch
    BOOL _holdFired;      // hold threshold already reached
    CGPoint _startWindow;
    NSInteger _generation; // invalidates a pending delayed hold
}

- (void)scheduleHold {
    NSInteger gen = ++_generation;
    CGPoint start = _startWindow;
    __weak ApolloHoldTouchRecognizer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHoldActivationDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloHoldTouchRecognizer *s = weakSelf;
        if (!s || s->_generation != gen || s->_holdFired || !s->_armed) return;
        s->_holdFired = YES;
        if (s.onHoldElapsed) s.onHoldElapsed(start);
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (_armed) return;                        // ignore extra fingers
    _armed = YES;
    _holdFired = NO;
    _startWindow = [touches.anyObject locationInView:nil];   // window coordinates
    if (self.onTouchDown) self.onTouchDown(_startWindow);
    [self scheduleHold];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (!_armed || _holdFired) return;          // after engage, ignore drift
    CGPoint p = [touches.anyObject locationInView:nil];
    if (hypot(p.x - _startWindow.x, p.y - _startWindow.y) > kHoldMoveTolerance) {
        _generation++;                          // cancel the pending hold
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self finish];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self finish];
}

- (void)reset {
    [super reset];
    [self finish];
}

- (void)finish {
    if (!_armed) return;
    _generation++;
    _armed = NO;
    _holdFired = NO;
    if (self.onTouchUp) self.onTouchUp();
}

@end

#pragma mark - Handler

@interface ApolloHoldSpeedHandler : NSObject
@property (nonatomic, weak) UIViewController *mediaViewer;
@property (nonatomic, strong) ApolloHoldTouchRecognizer *recognizer;
@property (nonatomic, strong) UIView *overlayView;
// Apollo's context-menu interaction(s), removed while a right-zone touch is down
// and re-added on release. Parallel arrays (interaction + the view it belongs to).
@property (nonatomic, strong) NSArray<UIContextMenuInteraction *> *suppressedInteractions;
@property (nonatomic, strong) NSArray<UIView *> *suppressedInteractionViews;
@property (nonatomic, assign) BOOL inZone;     // current touch began in the right third
@property (nonatomic, assign) BOOL active;     // 2× currently engaged
@property (nonatomic, assign) float preHoldRate;
// The exact AVPlayer we sped up, held strongly so we restore *that* instance on
// release — not one re-resolved from the (possibly torn-down) media viewer. For
// shared v.redd.it players, re-resolving could miss the restore and leave the
// feed/comments copy stuck at 2×.
@property (nonatomic, strong) AVPlayer *engagedPlayer;
- (void)installOnView:(UIView *)view;
@end

@implementation ApolloHoldSpeedHandler

- (void)installOnView:(UIView *)view {
    if (self.recognizer || !view) return;

    ApolloHoldTouchRecognizer *gr = [[ApolloHoldTouchRecognizer alloc] init];
    gr.cancelsTouchesInView = NO;
    gr.delaysTouchesBegan = NO;
    gr.delaysTouchesEnded = NO;

    __weak ApolloHoldSpeedHandler *weakSelf = self;
    gr.onTouchDown   = ^(CGPoint p) { [weakSelf touchDownAt:p]; };
    gr.onHoldElapsed = ^(CGPoint p) { [weakSelf holdElapsedAt:p]; };
    gr.onTouchUp     = ^{ [weakSelf touchUp]; };

    [view addGestureRecognizer:gr];
    self.recognizer = gr;
    ApolloLog(@"VideoHoldSpeed: installed on %@", NSStringFromClass([view class]));
}

#pragma mark Menu suppression

- (void)suppressMenu {
    UIView *root = self.mediaViewer.isViewLoaded ? self.mediaViewer.view : self.recognizer.view;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableArray<UIContextMenuInteraction *> *interactions = [NSMutableArray array];
    CollectContextMenuInteractions(root, views, interactions);
    for (NSUInteger i = 0; i < interactions.count; i++) {
        [views[i] removeInteraction:interactions[i]];
    }
    self.suppressedInteractionViews = views;
    self.suppressedInteractions = interactions;
    ApolloLog(@"VideoHoldSpeed: removed %lu context-menu interaction(s)", (unsigned long)interactions.count);
}

- (void)restoreMenu {
    NSArray<UIContextMenuInteraction *> *interactions = self.suppressedInteractions;
    NSArray<UIView *> *views = self.suppressedInteractionViews;
    for (NSUInteger i = 0; i < interactions.count; i++) {
        [views[i] addInteraction:interactions[i]];
    }
    self.suppressedInteractions = nil;
    self.suppressedInteractionViews = nil;
}

#pragma mark Zone detection

// True when `windowPoint` is in the right third of the VIDEO as currently
// displayed, in any orientation. Projects the touch onto the video's on-screen
// left→right axis (between the video view's left- and right-edge midpoints in
// window space), so it follows the video's real geometry under rotation/zoom.
- (BOOL)pointInActivationZone:(CGPoint)windowPoint {
    if (!MediaViewerPlayer(self.mediaViewer)) return NO;

    UIView *v = MediaVideoView(self.mediaViewer);
    UIWindow *win = v.window;
    if (!v || !win) return NO;
    CGSize b = v.bounds.size;
    if (b.width <= 0 || b.height <= 0) return NO;

    CGPoint leftMid  = [v convertPoint:CGPointMake(0,       b.height / 2) toView:win];
    CGPoint rightMid = [v convertPoint:CGPointMake(b.width, b.height / 2) toView:win];

    CGFloat dx = rightMid.x - leftMid.x;
    CGFloat dy = rightMid.y - leftMid.y;
    CGFloat len2 = dx * dx + dy * dy;
    if (len2 <= 0) return NO;

    CGFloat t = ((windowPoint.x - leftMid.x) * dx + (windowPoint.y - leftMid.y) * dy) / len2;
    return t >= (1.0 - kRightZoneFraction);
}

#pragma mark Touch lifecycle

- (void)touchDownAt:(CGPoint)windowPoint {
    self.inZone = [self pointInActivationZone:windowPoint];
    // Remove the context-menu interaction the instant a right-zone touch lands, so
    // the menu can never appear for this press. Left/center is left alone → normal
    // menu. Restored on release.
    if (self.inZone) [self suppressMenu];
}

- (void)holdElapsedAt:(CGPoint)windowPoint {
    if (!self.inZone || self.active) return;
    AVPlayer *player = MediaViewerPlayer(self.mediaViewer);
    if (!player) { ApolloLog(@"VideoHoldSpeed: holdElapsed — no player"); return; }

    self.engagedPlayer = player;      // restore THIS exact instance on release
    self.preHoldRate = player.rate;   // 0 if paused, 1.0, or a custom menu speed
    self.active = YES;
    [player setRate:kHoldSpeed];
    [self showOverlay];
    ApolloLog(@"VideoHoldSpeed: engaged 2x (prevRate=%.2f)", self.preHoldRate);
}

- (void)touchUp {
    [self restoreMenu];
    self.inZone = NO;
    if (!self.active) return;
    self.active = NO;
    // Restore the SAME player we sped up — not one re-resolved from the media
    // viewer, which may be a different instance (compact posts spin up a fresh
    // comments player) or nil (a swipe-to-dismiss while holding can tear down the
    // weak mediaViewer before the finger lifts). Missing the restore on a shared
    // v.redd.it player would leave the feed/comments copy stuck at 2×.
    [self.engagedPlayer setRate:self.preHoldRate];
    self.engagedPlayer = nil;
    [self hideOverlay];
    ApolloLog(@"VideoHoldSpeed: released (restored rate=%.2f)", self.preHoldRate);
}

// Safety net: if the handler is deallocated mid-hold (e.g. the media viewer is
// torn down by a flick-dismiss before the touch ends, so -touchUp never fires),
// still reset the player we sped up. engagedPlayer is strong, so it's alive here.
- (void)dealloc {
    if (self.active && self.engagedPlayer) {
        [self.engagedPlayer setRate:self.preHoldRate];
    }
}

#pragma mark Overlay

- (void)showOverlay {
    UIView *host = self.mediaViewer.isViewLoaded ? self.mediaViewer.view : self.recognizer.view;
    if (!host) return;

    if (!self.overlayView) {
        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.layer.cornerRadius = 16.0;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;

        UILabel *label = [[UILabel alloc] init];
        // "2× ⏵⏵" — U+00D7 multiplication sign, U+23F5 double right-pointing.
        label.attributedText = ({
            NSString *s = [NSString stringWithFormat:@"2%C ⏵⏵", (unichar)0x00D7];
            [[NSAttributedString alloc] initWithString:s attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor whiteColor],
            }];
        });
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [blur.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:14.0],
            [label.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-14.0],
            [label.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor constant:8.0],
            [label.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor constant:-8.0],
        ]];
        self.overlayView = blur;
    }

    UIView *overlay = self.overlayView;
    if (overlay.superview != host) {
        [overlay removeFromSuperview];
        overlay.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:overlay];
        [NSLayoutConstraint activateConstraints:@[
            [overlay.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
            [overlay.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:24.0],
        ]];
    }
    [host bringSubviewToFront:overlay];
    overlay.alpha = 0.0;
    [UIView animateWithDuration:0.15 animations:^{ overlay.alpha = 1.0; }];
}

- (void)hideOverlay {
    UIView *overlay = self.overlayView;
    if (!overlay) return;
    [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 0.0; }];
}

@end

#pragma mark - Install hook

static char kHoldSpeedHandlerKey;

static void InstallHoldSpeed(UIViewController *mvc) {
    if (!mvc) return;
    ApolloHoldSpeedHandler *existing = objc_getAssociatedObject(mvc, &kHoldSpeedHandlerKey);
    if (existing.recognizer) return;   // already installed

    // Attach to the controller's root view (stable, never transform-rotated) so
    // we receive touches anywhere on screen; the activation zone is computed
    // against the video's live on-screen geometry, so it's orientation-correct.
    UIView *targetView = mvc.isViewLoaded ? mvc.view : nil;
    if (!targetView) return;   // not ready; a later layout pass retries

    ApolloHoldSpeedHandler *handler = existing ?: [[ApolloHoldSpeedHandler alloc] init];
    handler.mediaViewer = mvc;
    objc_setAssociatedObject(mvc, &kHoldSpeedHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [handler installOnView:targetView];
}

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    InstallHoldSpeed((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    InstallHoldSpeed((UIViewController *)self);   // retry if -viewDidAppear: ran too early
}

%end

%ctor {
    ApolloLog(@"ApolloVideoHoldSpeed: module loaded (hold right third for 2x)");
}
