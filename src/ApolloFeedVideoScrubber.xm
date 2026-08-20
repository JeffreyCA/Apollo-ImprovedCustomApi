// ApolloFeedVideoScrubber.xm
//
// "Feed Video Scrubber" — grab the thin progress bar at the bottom of an
// inline video and slide left or right to scrub it, without opening the
// fullscreen player. Covers feed cells AND the post's own video at the top
// of comments. Off by default (sFeedVideoScrubber, toggle under
// Posts & Feeds).
//
//     ┌────────────────────────────────────┐
//     │                                    │
//     │            feed video              │
//     │                                    │
//     │ ▬▬▬▬▬▬▬▬▬▬▬●━━━━━━━━━━━━━━━━━━━━━━ │  ← Apollo's own progress strip;
//     └────────────────────────────────────┘    hold it and slide to scrub
//
// Interaction model (v2 — reworked with the user after a tap-summoned overlay
// bar turned out to be the wrong shape; there is deliberately NO new chrome):
//
//   • The EXISTING bottom progress strip (RichMediaNode.videoGIFProgressView,
//     a 5pt UIVisualEffectView pinned across the video's bottom) IS the
//     scrubber. An invisible touch strip covers the bottom kStripHeight points
//     of the video picture and drives the player; Apollo's own progress
//     updates move the visible strip, so what you grab is what moves.
//   • Touch the strip and slide — no hold required: a UIGestureRecognizer
//     subclass observes the touch the instant it lands (the scroll view's
//     touch delay only holds back VIEW delivery, never recognizers) and the
//     playback position follows the finger's absolute position on the bar
//     (finger at 1/3 of the width ≈ 1/3 of the video).
//   • Direction classifies the touch, deterministically: horizontal
//     dominance scrubs (any speed), vertical dominance fails to the feed
//     scroll. The bar owns horizontal gestures outright; swipe back/forward
//     navigation owns the rest of the video.
//   • While the finger is on the bar the time-based hold blockers (the feed
//     context menu's driver, drag lifts) are quiet, and while a scrub is live
//     the interactive pop, Apollo's swipe-anywhere pans, and the list's
//     scrolling are all suspended, so a drag can't pop the screen or bob the
//     feed. All restored the moment the touch ends, with a dealloc backstop.
//   • A quick tap on the strip is forwarded to the stock open-fullscreen
//     route (didTapVideoNode:), so the bottom of a video never becomes a
//     dead zone for the tap everyone already knows.
//   • Player type doesn't matter — v.redd.it keeps its player on the
//     AVPlayerLayer, RedGifs / Streamable / sports clips / GIF-mp4s keep it
//     on the video node — because the player is resolved AT TOUCH TIME via
//     the unmute module's shared helper, which tries both in that order.
//     Badge-"GIF" posts whose animation is a Texture animated image have no
//     playing AVPlayer and no native progress strip; the strip refuses the
//     hit outright (pointInside), so their touches pass through untouched.
//   • GIF-mp4s usually have a real AVPlayer but NO native progress strip:
//     Apollo creates videoGIFProgressView asynchronously and for feed GIFs
//     mostly never does, so they read as a dead zone here even though the
//     player is perfectly seekable. When a playable player exists and the
//     native strip is missing, a fallback strip stands in for it (drawn to
//     the native strip's shape, kept fresh by a timer that re-resolves the
//     player each tick since feed players churn constantly). It hides again
//     the moment Apollo's own strip shows up; pointInside accepts either.
//
// The touch strip is installed lazily from the cell visibility events of
// LargePostCellNode (feed) and RichMediaHeaderCellNode/CommentsHeaderCellNode
// (the post's video in comments) — the same callbacks the feed-unmute feature
// rides in ApolloVideoUnmute.xm (separate %hooks in separate files; they
// chain). It lives as a subview of the RichMediaNode's view, so it dies with
// the cell, and it is retained by the node through an associated object.

#import "ApolloCommon.h"
#import "ApolloState.h"          // sFeedVideoScrubber
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Resolve the AVPlayer the same way the rest of the tweak does — the shareable
// v.redd.it path keeps its player on the playerLayer, not on the video node.
extern AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id videoNode);

// Videos shorter than this aren't worth scrubbing.
static const NSTimeInterval kMinimumScrubbableDuration = 1.0;

// Height of the invisible touch strip, anchored to the bottom of the video
// picture. Tall enough to grab with a thumb, short enough that the video's
// tap-to-open area stays essentially intact.
static const CGFloat kStripHeight = 32.0;

// The bottom-right corner of the video belongs to the mute button (and the
// GIF badge). Touches there fall through to it.
static const CGFloat kCornerExclusion = 56.0;

// The fallback strip matches the native strip's shape: a 5pt bar pinned
// across the bottom of the video picture.
static const CGFloat kFallbackStripHeight = 5.0;

// How often the fallback strip re-resolves its player and refreshes its fill.
static const NSTimeInterval kFallbackTickInterval = 0.25;

// A release that never moved this far is a tap.
static const CGFloat kScrubSlop = 6.0;

// The instant-scrub gesture (ApolloFeedScrubGesture): it observes the touch
// live — no waiting on the scroll view's touch delay — and classifies it by
// direction alone, so the same gesture always does the same thing:
//   • horizontal dominance past kGestureBeginDistance → scrub NOW, any speed
//   • vertical dominance past kGestureVerticalFail → fail, the feed scrolls
// The bar deterministically owns horizontal gestures; swipe back/forward
// navigation owns the rest of the video (a velocity split was tried and
// rejected — the same flick would sometimes scrub and sometimes navigate,
// which reads as broken).
static const CGFloat kGestureBeginDistance = 5.0;
static const CGFloat kGestureVerticalFail = 8.0;

// A press shorter than this with no slide is a tap, forwarded to the stock
// open-fullscreen route. Longer means the user grabbed the bar deliberately —
// releasing without sliding then does nothing.
static const NSTimeInterval kForwardTapMaxDuration = 0.3;

#pragma mark - Helpers

static id NodeIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            @try { return object_getIvar(object, ivar); }
            @catch (__unused NSException *e) { return nil; }
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// A loaded node's view, without forcing a view to be created off-screen.
static UIView *ViewForNode(id node) {
    if (!node) return nil;
    if ([node respondsToSelector:@selector(isNodeLoaded)]
        && !((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded))) {
        return nil;
    }
    if (![node respondsToSelector:@selector(view)]) return nil;
    return ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
}

// The view controller a view currently lives in, for reaching its navigation
// controller's interactive-pop recognizer.
static UIViewController *ViewControllerForView(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
    }
    return nil;
}

// Two families of competing gestures, suspended at two different moments:
//
// HOLD BLOCKERS (suspended the moment the hold is delivered): the time-based
// recognizers that fire on a stationary press — the context menu's driver
// (which on iOS 26 is NOT a UILongPressGestureRecognizer subclass; a
// class-list allowlist missed it and it cancelled the hold ~400ms in), drag
// lifts, and friends. Deny-by-default: everything that is neither a pan nor a
// plain tap (taps only fire on touch-up, when the scrub is over anyway).
//
// NAVIGATION PANS (suspended only once a scrub ENGAGES): Apollo's
// swipe-anywhere back/forward, the interactive pop, swipe actions. A QUICK
// swipe across the bar must keep navigating exactly like anywhere else on the
// video — those pans stay armed through the hold and are only taken away when
// deliberate horizontal movement after the hold turns the touch into a scrub
// (engagement at 6pt beats a pan's ~10pt activation, so a real scrub is never
// stolen mid-drag).
//
// The feed's own scroll pan is deliberately left alone in both passes —
// cancelling it is the scroll view's business, and the engaged scrub locks
// scrolling via scrollEnabled instead. All mirrors ApolloStatsRowTouch.xm's
// loupe handling.
static NSArray<UIGestureRecognizer *> *SuspendHoldBlockingGestures(UIView *view) {
    NSMutableArray<UIGestureRecognizer *> *disabled = [NSMutableArray array];
    // Ancestors only: the strip's own scrub recognizer lives on `view`, and it
    // is neither a pan nor a tap — walking from `view` itself disabled OUR OWN
    // gesture from inside its touchesBegan, killing every drag at birth.
    for (UIView *v = view.superview; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == scrollPan || !g.isEnabled) continue;
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) continue;
            if ([g isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            g.enabled = NO;
            [disabled addObject:g];
        }
    }
    return disabled;
}

static NSArray<UIGestureRecognizer *> *SuspendNavigationPans(UIView *view) {
    NSMutableArray<UIGestureRecognizer *> *disabled = [NSMutableArray array];

    UIGestureRecognizer *pop =
        ViewControllerForView(view).navigationController.interactivePopGestureRecognizer;
    if (pop && pop.isEnabled) { pop.enabled = NO; [disabled addObject:pop]; }

    for (UIView *v = view.superview; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == scrollPan || !g.isEnabled) continue;
            if (![g isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            g.enabled = NO;
            [disabled addObject:g];
        }
    }
    return disabled;
}

static void RestoreCompetingGestures(NSArray<UIGestureRecognizer *> *disabled) {
    for (UIGestureRecognizer *g in disabled) g.enabled = YES;
}

// The AVPlayerLayer showing this video, so the strip can be sized to the
// picture itself rather than to the node that hosts it.
static AVPlayerLayer *PlayerLayerInLayer(CALayer *layer) {
    if (!layer) return nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) return (AVPlayerLayer *)layer;
    for (CALayer *sub in layer.sublayers) {
        AVPlayerLayer *found = PlayerLayerInLayer(sub);
        if (found) return found;
    }
    return nil;
}

// The rect the video actually occupies, in `host` coordinates. A 16:9 clip in
// a taller node is letterboxed, so the node's frame is wider (or taller) than
// the picture — the native progress strip hugs the picture, and the touch
// strip must hug the same edge. AVPlayerLayer.videoRect is the picture's real
// rect once the layer is ready; fall back to the node's own bounds before then
// (and for non-shareable players, whose layer fills the node anyway).
static CGRect VideoContentRectInHost(UIView *videoView, UIView *host) {
    CGRect fallback = [videoView convertRect:videoView.bounds toView:host];
    AVPlayerLayer *playerLayer = PlayerLayerInLayer(videoView.layer);
    if (!playerLayer) return fallback;

    CGRect videoRect = playerLayer.videoRect;
    if (CGRectIsEmpty(videoRect) || videoRect.size.width < 1 || videoRect.size.height < 1) {
        return fallback;
    }
    CGRect inVideoView = [videoView.layer convertRect:videoRect fromLayer:playerLayer];
    CGRect inHost = [videoView convertRect:inVideoView toView:host];
    // Guard against a stale/oversized videoRect during a resize: never grow
    // beyond the node itself.
    return CGRectIsEmpty(inHost) ? fallback : CGRectIntersection(inHost, fallback);
}

// Total duration in seconds, or 0 when the item is missing, still loading, or
// live/indefinite (scrubbing an unknown length would be a lie).
static NSTimeInterval ScrubbableDuration(AVPlayer *player) {
    AVPlayerItem *item = player.currentItem;
    if (!item) return 0;
    CMTime duration = item.duration;
    if (!CMTIME_IS_NUMERIC(duration)) return 0;
    NSTimeInterval seconds = CMTimeGetSeconds(duration);
    if (!isfinite(seconds) || seconds < kMinimumScrubbableDuration) return 0;
    return seconds;
}

#pragma mark - Fallback progress strip (GIF-mp4s without a native strip)

// A visible stand-in for videoGIFProgressView on content that never gets one.
// Purely visual: touches go to the invisible touch strip exactly as for
// videos. Re-resolves its player on every tick rather than holding one, since
// feed players are created and torn down constantly as cells scroll.
@interface ApolloFeedScrubFallbackStrip : UIView
@property (nonatomic, weak) id richMediaNode;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) CGFloat lastFraction;
// While a scrub drag is live the finger owns the fill and the tick must not
// fight it with the playhead.
@property (nonatomic, assign) BOOL suspendAutoUpdates;
- (void)setFillFraction:(CGFloat)fraction;
@end

@implementation ApolloFeedScrubFallbackStrip

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.hidden = YES;   // shown by the first tick that finds a playable player
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.3];

    UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
    fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    [self addSubview:fill];
    self.fillView = fill;
    return self;
}

// Tick only while in a window; cells leaving the screen take their views out
// of the window, which is exactly when ticking should stop. Block-based with
// a weak self so the timer never pins the strip or its cell alive.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        return;
    }
    if (self.tickTimer) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kFallbackTickInterval
                                            repeats:YES
                                              block:^(NSTimer *t) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        [strongSelf tick];
    }];
    timer.tolerance = kFallbackTickInterval / 2.0;
    // Common modes so the fill keeps moving while the feed scrolls.
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.tickTimer = timer;
    [self tick];
}

- (void)dealloc {
    [_tickTimer invalidate];
}

- (void)tick {
    if (self.suspendAutoUpdates) return;
    if (!sFeedVideoScrubber) { self.hidden = YES; return; }

    // Defer to Apollo's own strip the moment it materializes.
    UIView *nativeStrip = NodeIvar(self.richMediaNode, "videoGIFProgressView");
    if ([nativeStrip isKindOfClass:[UIView class]] && !nativeStrip.hidden) {
        self.hidden = YES;
        return;
    }

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    NSTimeInterval duration = player ? ScrubbableDuration(player) : 0;
    if (!player || duration <= 0) {
        self.hidden = YES;
        return;
    }

    NSTimeInterval current = CMTimeGetSeconds(player.currentTime);
    if (!isfinite(current) || current < 0) current = 0;
    if (self.hidden) {
        self.hidden = NO;
        ApolloLog(@"[FeedScrubber] fallback strip live on %p (no native strip; duration=%.1fs)",
                  (void *)self.richMediaNode, duration);
    }
    [self setFillFraction:(CGFloat)(current / duration)];
}

- (void)setFillFraction:(CGFloat)fraction {
    self.lastFraction = MAX(0.0, MIN(1.0, fraction));
    CGRect bounds = self.bounds;
    self.fillView.frame = CGRectMake(0, 0, self.lastFraction * bounds.size.width, bounds.size.height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self setFillFraction:self.lastFraction];
}

@end

#pragma mark - Touch strip

// One invisible UIControl per feed RichMediaNode, covering the bottom strip of
// the video picture. Everything it needs (player, duration, the native strip's
// presence) is resolved per-touch, never cached across touches — feed players
// are created and torn down constantly as cells scroll.
//
// Two touch paths share it:
//   • ApolloFeedScrubGesture (below) — a recognizer, so it sees the touch the
//     instant it lands instead of waiting out the scroll view's ~150ms touch
//     delay. It does ALL the scrubbing: drag the bar and it seeks right away,
//     no hold required.
//   • UIControl tracking — only ever receives the delayed/replayed delivery,
//     and is kept purely so a plain TAP on the strip still opens fullscreen.
@interface ApolloFeedScrubStrip : UIControl
@property (nonatomic, weak) id richMediaNode;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, strong) AVPlayer *player;              // touch-scoped
@property (nonatomic, assign) NSTimeInterval duration;       // touch-scoped
@property (nonatomic, weak) UIView *nativeStripView;         // touch-scoped
@property (nonatomic, weak) ApolloFeedScrubFallbackStrip *fallbackStrip;   // wired by EnsureScrubStrip
@property (nonatomic, assign) BOOL pausedForScrub;           // touch-scoped
@property (nonatomic, weak) UIScrollView *lockedScrollView;  // touch-scoped
@property (nonatomic, assign) BOOL scrubbing;                // gesture Began..Ended
@property (nonatomic, assign) CGFloat startX;
@property (nonatomic, assign) CFTimeInterval touchStartedAt;
@property (nonatomic, assign) BOOL movedTooFarForTap;
@property (nonatomic, strong) NSArray<UIGestureRecognizer *> *suspendedGestures;
@property (nonatomic, strong) UIGestureRecognizer *scrubGesture;
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *deferredPans;
@property (nonatomic, assign) BOOL seekInFlight;
@property (nonatomic, assign) BOOL hasPendingSeek;
@property (nonatomic, assign) CMTime pendingSeekTime;
- (void)scrubTouchLanded;
- (void)scrubGestureDidReset;
- (void)wireFailureRequirements;
- (CGFloat)fractionForLocationX:(CGFloat)x;
@end

// The instant path: a UIGestureRecognizer subclass observes touches live (the
// scroll view's delaysContentTouches only delays VIEW delivery, never
// recognizers), so a drag on the bar can start seeking immediately. Direction
// and speed decide the touch's fate — see the constants above. Once this
// recognizer Begins, UIKit's default mutual exclusion prevents every other
// recognizer on the touch (scroll pan, back/forward pans), so nothing fights
// the drag; when it Fails, those recognizers proceed exactly as stock.
@interface ApolloFeedScrubGesture : UIGestureRecognizer
@property (nonatomic, assign) CGPoint startPoint;
@end

@implementation ApolloFeedScrubGesture

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.numberOfTouches > 1) { self.state = UIGestureRecognizerStateFailed; return; }
    UITouch *touch = touches.anyObject;
    self.startPoint = [touch locationInView:self.view];
    // Kill the time-based hold blockers (context menu, drag lift) right at
    // touch-down — the strip owns holds. Restored in -reset for every outcome.
    [(ApolloFeedScrubStrip *)self.view scrubTouchLanded];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:self.view];

    if (self.state == UIGestureRecognizerStatePossible) {
        CGFloat dx = fabs(point.x - self.startPoint.x);
        CGFloat dy = fabs(point.y - self.startPoint.y);
        if (dy >= kGestureVerticalFail && dy > dx) {
            self.state = UIGestureRecognizerStateFailed;   // a scroll
            return;
        }
        if (dx >= kGestureBeginDistance && dx > dy) {
            self.state = UIGestureRecognizerStateBegan;    // a scrub, any speed
        }
        return;
    }
    if (self.state == UIGestureRecognizerStateBegan
        || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL active = self.state == UIGestureRecognizerStateBegan
               || self.state == UIGestureRecognizerStateChanged;
    self.state = active ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL active = self.state == UIGestureRecognizerStateBegan
               || self.state == UIGestureRecognizerStateChanged;
    self.state = active ? UIGestureRecognizerStateCancelled : UIGestureRecognizerStateFailed;
}

- (void)reset {
    [super reset];
    [(ApolloFeedScrubStrip *)self.view scrubGestureDidReset];
}

@end

static char kFeedScrubStripKey;
static char kFeedScrubFallbackKey;

@implementation ApolloFeedScrubStrip

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Video progress";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;

    ApolloFeedScrubGesture *gesture = [[ApolloFeedScrubGesture alloc] init];
    [gesture addTarget:self action:@selector(handleScrubGesture:)];
    [self addGestureRecognizer:gesture];
    self.scrubGesture = gesture;
    self.deferredPans = [NSHashTable weakObjectsHashTable];
    return self;
}

// Race-free arbitration with the navigation pans: a failure requirement makes
// each ancestor pan (and the interactive pop) formally WAIT for this strip's
// gesture to fail before it may begin on a touch the strip is tracking. When
// the gesture classifies the touch as a flick or a scroll it fails within the
// first few points of movement and the pans proceed; when it begins a scrub
// they are blocked outright. Touches that never hit the strip never enter its
// gesture's arena, so the requirement is vacuous there — navigation elsewhere
// on the screen is untouched. (Without this, both recognizers classify the
// same move event and whoever runs first wins — the pop gesture was beating
// the strip to a slow drag and popping the screen instead of scrubbing.)
- (void)wireFailureRequirements {
    UIGestureRecognizer *gesture = self.scrubGesture;
    if (!gesture) return;

    UIGestureRecognizer *pop =
        ViewControllerForView(self).navigationController.interactivePopGestureRecognizer;
    if (pop && ![self.deferredPans containsObject:pop]) {
        [pop requireGestureRecognizerToFail:gesture];
        [self.deferredPans addObject:pop];
    }

    for (UIView *v = self.superview; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == scrollPan) continue;   // scrolling stays fully stock
            if (![g isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            if ([self.deferredPans containsObject:g]) continue;
            [g requireGestureRecognizerToFail:gesture];
            [self.deferredPans addObject:g];
        }
    }
}

- (void)dealloc {
    // Suspended recognizers must never outlive a touch, whatever tore us down,
    // and neither must a scrub-pause or the scroll lock.
    RestoreCompetingGestures(_suspendedGestures);
    if (_pausedForScrub && _player) [_player play];
    if (_lockedScrollView) _lockedScrollView.scrollEnabled = YES;
    _fallbackStrip.suspendAutoUpdates = NO;
}

#pragma mark Hit testing

// The strip only exists for touches it can actually serve. Everything else —
// feature off, no playable video yet, no native progress strip to mirror the
// scrub, the mute-button corner — falls straight through to whatever is
// underneath, so stock behavior is untouched in every state but "scrubbable".
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!sFeedVideoScrubber) return NO;
    if (![super pointInside:point withEvent:event]) return NO;
    if (point.x > self.bounds.size.width - kCornerExclusion) return NO;

    // From here down the touch is genuinely on the strip, so a refusal is
    // worth naming — it is the difference between "scrub" and "dead zone".
    // Either visible bar will do: Apollo's own strip, or the fallback one
    // standing in for it on GIF-mp4s.
    UIView *nativeStrip = NodeIvar(self.richMediaNode, "videoGIFProgressView");
    BOOL nativeVisible = [nativeStrip isKindOfClass:[UIView class]] && !nativeStrip.hidden;
    BOOL fallbackVisible = self.fallbackStrip && !self.fallbackStrip.hidden;
    if (!nativeVisible && !fallbackVisible) {
        ApolloLog(@"[FeedScrubber] refusing touch: native strip %@, no fallback",
                  nativeStrip ? @"hidden" : @"missing");
        return NO;
    }

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    NSTimeInterval duration = player ? ScrubbableDuration(player) : 0;
    if (!player || duration <= 0) {
        ApolloLog(@"[FeedScrubber] refusing touch: player=%p duration=%.1f", player, duration);
        return NO;
    }
    return YES;
}

#pragma mark Accessibility

// VoiceOver scrubs in 5% steps without needing the hold-and-slide gesture.
- (NSString *)accessibilityValue {
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    NSTimeInterval duration = player ? ScrubbableDuration(player) : 0;
    if (duration <= 0) return nil;
    NSTimeInterval current = CMTimeGetSeconds([player currentTime]);
    if (!isfinite(current) || current < 0) current = 0;
    return [NSString stringWithFormat:@"%ld%%", (long)llround(current / duration * 100.0)];
}

- (void)accessibilityNudgeBy:(NSTimeInterval)delta {
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    NSTimeInterval duration = player ? ScrubbableDuration(player) : 0;
    if (duration <= 0) return;
    NSTimeInterval current = CMTimeGetSeconds([player currentTime]);
    if (!isfinite(current) || current < 0) current = 0;
    NSTimeInterval target = MAX(0.0, MIN(duration, current + delta));
    [player seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
       toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)accessibilityIncrement {
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    [self accessibilityNudgeBy:ScrubbableDuration(player) * 0.05];
}

- (void)accessibilityDecrement {
    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    [self accessibilityNudgeBy:-ScrubbableDuration(player) * 0.05];
}

#pragma mark Scrub gesture

- (CGFloat)fractionForLocationX:(CGFloat)x {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return 0;
    return MAX(0.0, MIN(1.0, x / width));
}

// Recognizer touch-down: the strip owns holds, so the time-based hold
// blockers (context menu, drag lift) go quiet immediately. The navigation
// pans and the scroll pan are left completely alone — the recognizer's
// classification decides the touch's fate, and if it Fails they proceed as
// stock. Restored in -scrubGestureDidReset, which fires for every outcome.
- (void)scrubTouchLanded {
    if (!self.suspendedGestures.count) {
        self.suspendedGestures = SuspendHoldBlockingGestures(self);
    }
}

- (void)scrubGestureDidReset {
    if (!self.scrubbing) [self restoreSuspendedGestures];
}

- (void)handleScrubGesture:(ApolloFeedScrubGesture *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            // Re-resolve everything: pointInside vetted the touch at
            // hit-test, but the player can change between then and now.
            self.player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
            self.duration = self.player ? ScrubbableDuration(self.player) : 0;
            if (!self.player || self.duration <= 0) { self.player = nil; return; }

            self.scrubbing = YES;
            self.hasPendingSeek = NO;
            UIView *nativeStrip = NodeIvar(self.richMediaNode, "videoGIFProgressView");
            self.nativeStripView = [nativeStrip isKindOfClass:[UIView class]] ? nativeStrip : nil;
            // The finger owns the fallback's fill for the drag.
            self.fallbackStrip.suspendAutoUpdates = YES;

            // UIKit's mutual exclusion already fails other recognizers on
            // this touch once we Begin — but Apollo's swipe-anywhere pans are
            // custom recognizers whose delegates may permit simultaneous
            // recognition, so take them out explicitly for the drag too.
            NSMutableArray *suspended =
                [NSMutableArray arrayWithArray:self.suspendedGestures ?: @[]];
            [suspended addObjectsFromArray:SuspendNavigationPans(self)];
            self.suspendedGestures = suspended;

            CGFloat fraction = [self fractionForLocationX:[gesture locationInView:self].x];
            ApolloLog(@"[FeedScrubber] scrub engaged at %.0f%% (duration=%.1fs)",
                      fraction * 100.0, self.duration);

            // Lock the list so vertical finger drift can't bob it under the
            // drag (stats-row loupe pattern; restored on every exit path)...
            for (UIView *v = self.superview; v; v = v.superview) {
                if ([v isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *scrollView = (UIScrollView *)v;
                    if (scrollView.isScrollEnabled) {
                        scrollView.scrollEnabled = NO;
                        self.lockedScrollView = scrollView;
                    }
                    break;
                }
            }

            // ...and pause for the duration of the drag, like every standard
            // scrubber: with playback stopped, Apollo's progress observer
            // only fires as seeks land (≈ the finger position), so it stops
            // fighting the finger-tracked bar with stale playhead widths —
            // and the drag stops playing chopped-up audio. Resumed on
            // release/cancel, with a dealloc backstop. The player is never
            // rate-changed outside the touch.
            if (self.player.rate > 0) {
                self.pausedForScrub = YES;
                [self.player pause];
            }

            [self trackFingerOnNativeStrip:fraction];
            [self scrubToFraction:fraction finished:NO];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.scrubbing) return;
            CGFloat fraction = [self fractionForLocationX:[gesture locationInView:self].x];
            [self trackFingerOnNativeStrip:fraction];
            [self scrubToFraction:fraction finished:NO];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (!self.scrubbing) return;
            CGFloat fraction = [self fractionForLocationX:[gesture locationInView:self].x];
            [self scrubToFraction:fraction finished:YES];
            [self finishScrub];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (self.scrubbing) [self finishScrub];
            break;
        }
        default:
            break;
    }
}

- (void)finishScrub {
    self.scrubbing = NO;
    self.fallbackStrip.suspendAutoUpdates = NO;
    [self restoreSuspendedGestures];
    [self unlockScrollView];
    [self resumeIfPausedForScrub];
    self.player = nil;
}

- (void)unlockScrollView {
    UIScrollView *locked = self.lockedScrollView;
    if (locked) locked.scrollEnabled = YES;
    self.lockedScrollView = nil;
}

#pragma mark Tap tracking

// UIControl tracking only ever sees the scroll view's delayed/replayed
// delivery — the gesture above owns all scrubbing. This path exists so a
// plain tap on the strip still opens the video fullscreen.

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.startX = [touch locationInView:self].x;
    self.touchStartedAt = CACurrentMediaTime();
    self.movedTooFarForTap = NO;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (fabs([touch locationInView:self].x - self.startX) >= kScrubSlop) {
        // Includes a fast flick's post-lift replay burst: not a tap, and the
        // gesture (which saw it live) already classified it — do nothing.
        self.movedTooFarForTap = YES;
    }
    return YES;
}

// The native strip is driven by Apollo's progress observer, which only moves
// as each seek actually lands — on slow-seeking streams that reads as the bar
// stuttering after the finger. While a drag is live, write the strip's fill
// from the finger directly so the grab feels instant; Apollo's next progress
// update simply takes over again after release (and with the player paused
// for the drag, its updates come from landed seeks ≈ the finger anyway).
//
// VideoGIFProgressView's shape (recovered at runtime): the effect view itself
// is the full-width track; its Swift `progress` property has no ObjC setter,
// and layoutSubviews lays the `progressBarView` ivar out from it. Setting the
// fill view's frame is the least invasive way in — no Swift ivar writes.
- (void)trackFingerOnNativeStrip:(CGFloat)fraction {
    UIView *fill = NodeIvar(self.nativeStripView, "progressBarView");
    if ([fill isKindOfClass:[UIView class]] && fill.superview) {
        CGRect frame = fill.frame;
        frame.size.width = MAX(0.0, MIN(1.0, fraction)) * fill.superview.bounds.size.width;
        fill.frame = frame;
        return;
    }
    // No native strip (GIF-mp4s): the fallback strip is the visible bar.
    ApolloFeedScrubFallbackStrip *fallback = self.fallbackStrip;
    if (fallback && !fallback.hidden) [fallback setFillFraction:fraction];
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!self.scrubbing && !self.movedTooFarForTap
        && CACurrentMediaTime() - self.touchStartedAt < kForwardTapMaxDuration) {
        // A plain tap: hand it to the stock route so tapping the bottom of a
        // video still opens it fullscreen, scrubber or no scrubber.
        id richMediaNode = self.richMediaNode;
        id videoNode = self.videoNode;
        if (richMediaNode && videoNode
            && [richMediaNode respondsToSelector:@selector(didTapVideoNode:)]) {
            ApolloLog(@"[FeedScrubber] quick tap on the strip - forwarding to fullscreen");
            ((void (*)(id, SEL, id))objc_msgSend)(richMediaNode, @selector(didTapVideoNode:), videoNode);
        }
    }
    self.movedTooFarForTap = NO;
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    // The gesture Beginning cancels view tracking — its own handler owns all
    // cleanup. Nothing to do here.
    self.movedTooFarForTap = NO;
}

- (void)restoreSuspendedGestures {
    RestoreCompetingGestures(self.suspendedGestures);
    self.suspendedGestures = nil;
}

// Play/pause across the drag must balance on every exit path — a video left
// paused would read as "the scrubber broke my feed video".
- (void)resumeIfPausedForScrub {
    if (!self.pausedForScrub) return;
    self.pausedForScrub = NO;
    [self.player play];
}

#pragma mark Seeking

// Chase-seek: at most one seek in flight, the newest requested position wins.
// The player is deliberately NOT paused for the drag — Apollo has several
// "snapshot the rate now, restore it later" paths (the fullscreen scrub, the
// mute dance's unpause) and a temporary rate change is exactly what made the
// hold-speed feature stick at 2x. Seeking a playing player sidesteps all of
// it, and Apollo's own progress observer moves the native strip as each seek
// lands, which is the only visual feedback this feature needs.
- (void)scrubToFraction:(CGFloat)fraction finished:(BOOL)finished {
    AVPlayer *player = self.player;
    if (!player || self.duration <= 0) return;

    NSTimeInterval target = MAX(0.0, MIN(self.duration, self.duration * fraction));
    CMTime targetTime = CMTimeMakeWithSeconds(target, NSEC_PER_SEC);
    if (finished) {
        self.hasPendingSeek = NO;
        [player seekToTime:targetTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        ApolloLog(@"[FeedScrubber] seek to %.1fs of %.1fs", target, self.duration);
        return;
    }

    self.pendingSeekTime = targetTime;
    if (self.seekInFlight) { self.hasPendingSeek = YES; return; }
    [self issueSeek:targetTime];
}

- (void)issueSeek:(CMTime)time {
    AVPlayer *player = self.player;
    if (!player) return;
    self.seekInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [player seekToTime:time completionHandler:^(__unused BOOL finished) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.seekInFlight = NO;
        if (strongSelf.hasPendingSeek) {
            strongSelf.hasPendingSeek = NO;
            [strongSelf issueSeek:strongSelf.pendingSeekTime];
        }
    }];
}

@end

#pragma mark - Installation

// Give a feed RichMediaNode its touch strip and keep the strip glued to the
// bottom of the video picture. Called from the cell's visibility events, so
// it re-asserts geometry as cells scroll, resize, and re-lay out.
static void EnsureScrubStrip(id richMediaNode) {
    if (!richMediaNode) return;

    UIView *host = ViewForNode(richMediaNode);
    if (!host) return;
    id videoNode = NodeIvar(richMediaNode, "videoNode");
    UIView *videoView = ViewForNode(videoNode);
    if (!videoView) return;   // image/text posts have no video to scrub

    ApolloFeedScrubStrip *strip = objc_getAssociatedObject(richMediaNode, &kFeedScrubStripKey);
    if (!strip) {
        strip = [[ApolloFeedScrubStrip alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(richMediaNode, &kFeedScrubStripKey, strip,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[FeedScrubber] strip installed on %p", (void *)richMediaNode);
    }
    strip.richMediaNode = richMediaNode;
    strip.videoNode = videoNode;

    if (strip.superview != host) [strip removeFromSuperview];
    if (!strip.superview) [host addSubview:strip];
    [strip wireFailureRequirements];

    // Never move the strip under the user's finger mid-scrub. (.tracking
    // covers the tap path; .scrubbing the gesture path — the gesture cancels
    // view tracking when it begins, so .tracking alone would miss it.)
    if (strip.tracking || strip.scrubbing) return;

    CGRect videoFrame = VideoContentRectInHost(videoView, host);
    if (CGRectIsEmpty(videoFrame)) return;
    CGRect stripFrame = CGRectMake(videoFrame.origin.x,
                                   CGRectGetMaxY(videoFrame) - kStripHeight,
                                   videoFrame.size.width,
                                   kStripHeight);
    strip.frame = stripFrame;

    // The fallback bar for content whose native strip never shows up.
    // Installed unconditionally and cheap when idle: its own tick hides it
    // whenever the native strip exists or there is no playable player, so on
    // ordinary videos it never appears.
    ApolloFeedScrubFallbackStrip *fallback =
        objc_getAssociatedObject(richMediaNode, &kFeedScrubFallbackKey);
    if (!fallback) {
        fallback = [[ApolloFeedScrubFallbackStrip alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(richMediaNode, &kFeedScrubFallbackKey, fallback,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fallback.richMediaNode = richMediaNode;
    fallback.videoNode = videoNode;
    strip.fallbackStrip = fallback;
    if (fallback.superview != host) [fallback removeFromSuperview];
    if (!fallback.superview) [host addSubview:fallback];
    fallback.frame = CGRectMake(videoFrame.origin.x,
                                CGRectGetMaxY(videoFrame) - kFallbackStripHeight,
                                videoFrame.size.width,
                                kFallbackStripHeight);

    // Touch strip stays on top of everything, fallback bar just under it.
    [host bringSubviewToFront:fallback];
    [host bringSubviewToFront:strip];
}

// ---------------------------------------------------------------------------
// LargePostCellNode: the feed's video cell. Same visibility callback the
// feed-unmute feature hooks in ApolloVideoUnmute.xm — separate %hooks in
// separate files chain normally. Events 0 (visible) and 1 (visible rect
// changed) both position the strip; 2 (invisible) needs nothing, the strip
// just goes off-screen with its cell.
//
// RichMediaHeaderCellNode / CommentsHeaderCellNode: the post's own video at
// the top of comments — the user wants the same hold-to-scrub there, so the
// strip rides those cells' visibility events too (the media is the same
// RichMediaNode either way).
// ---------------------------------------------------------------------------
%group FeedScrubStrip

%hook LargePostCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    %orig;
    if (!sFeedVideoScrubber) return;   // feature off: no per-tick work at all
    if (event != 0 && event != 1) return;

    EnsureScrubStrip(NodeIvar(self, "richMediaNode"));
    id crosspostNode = NodeIvar(self, "crosspostNode");
    if (crosspostNode) EnsureScrubStrip(NodeIvar(crosspostNode, "richMediaNode"));
}

%end

%end

%group ScrubStripCommentsHeader

%hook RichMediaHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    %orig;
    if (!sFeedVideoScrubber) return;
    if (event != 0 && event != 1) return;
    EnsureScrubStrip(NodeIvar(self, "richMediaNode"));
}

%end

%end

%group ScrubStripCommentsHeader2

%hook CommentsHeaderCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    %orig;
    if (!sFeedVideoScrubber) return;
    if (event != 0 && event != 1) return;
    EnsureScrubStrip(NodeIvar(self, "richMediaNode"));
}

%end

%end

%ctor {
    Class largePostCellClass = objc_getClass("_TtC6Apollo17LargePostCellNode");
    if (!largePostCellClass) {
        ApolloLog(@"[FeedScrubber] ctor: LargePostCellNode missing - feed scrubber unavailable");
        return;
    }
    %init(FeedScrubStrip, LargePostCellNode = largePostCellClass);

    // Each header class inits in its own group so a missing one (binary drift)
    // costs only that context, never the feed.
    Class headerCellClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    if (headerCellClass) {
        %init(ScrubStripCommentsHeader, RichMediaHeaderCellNode = headerCellClass);
    }
    Class commentsHeaderCellClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    if (commentsHeaderCellClass) {
        %init(ScrubStripCommentsHeader2, CommentsHeaderCellNode = commentsHeaderCellClass);
    }
    ApolloLog(@"[FeedScrubber] module loaded (hold a video's progress bar to scrub; comments header %@)",
              (headerCellClass || commentsHeaderCellClass) ? @"covered" : @"unavailable");
}
