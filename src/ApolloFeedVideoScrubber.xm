// ApolloFeedVideoScrubber.xm
//
// "Feed Video Scrubber" — press and hold the thin progress bar at the bottom
// of an inline video, then slide left or right to scrub it, without opening
// the fullscreen player. Covers feed cells AND the post's own video at the
// top of comments. Off by default (sFeedVideoScrubber, toggle under
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
//   • Press and hold the strip, then slide: playback position follows the
//     finger's absolute position on the bar (finger at 1/3 of the width ≈ 1/3
//     of the video), exactly like tapping into a scrubber anywhere else.
//   • The feed's own touch delay does the flick/scrub disambiguation for
//     free: UIScrollView holds content touches for ~150ms deciding whether
//     they start a scroll, so a scrolling flick over the strip never reaches
//     it, while a press-and-hold outlasts the window and is delivered here.
//     (This is the same delaysContentTouches behavior the v1 overlay had to
//     fight — for hold-to-scrub it is the correct gate, so it stays stock.)
//   • While the finger is down: the interactive pop, Apollo's
//     swipe-anywhere-back pan, and every ancestor long-press (the feed
//     context menu's driver) are suspended, so a scrub can't pop the screen
//     and a hold can't pop the menu. All restored the moment the touch ends,
//     with a dealloc backstop.
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

// A finger has to move this far horizontally before the hold becomes a scrub;
// below it a release is treated as a tap.
static const CGFloat kScrubSlop = 6.0;

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

// A horizontal drag on the strip is also a perfectly good "swipe back" as far
// as Apollo's swipe-anywhere-to-go-back gesture is concerned, and that gesture
// wins: it cancels UIControl tracking and pops the screen mid-scrub. A
// stationary hold is likewise a perfectly good context-menu press. Disable the
// pop recognizer, every pan-like ancestor, and every ancestor long-press for
// the duration of the touch only (mirrors ApolloStatsRowTouch.xm's loupe
// handling). The feed's own scroll pan is deliberately left alone — cancelling
// it is the scroll view's business, and UIScrollView already exempts tracking
// UIControls from touch cancellation.
static NSArray<UIGestureRecognizer *> *SuspendCompetingGestures(UIView *view) {
    NSMutableArray<UIGestureRecognizer *> *disabled = [NSMutableArray array];

    UIGestureRecognizer *pop =
        ViewControllerForView(view).navigationController.interactivePopGestureRecognizer;
    if (pop && pop.isEnabled) { pop.enabled = NO; [disabled addObject:pop]; }

    for (UIView *v = view; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == scrollPan || !g.isEnabled) continue;
            // Deny-by-default: iOS 26's context-menu driver is NOT a
            // UILongPressGestureRecognizer subclass (a class-list allowlist
            // missed it, and it cancelled the hold ~400ms in), so suspend
            // every ancestor recognizer except plain taps — those only fire
            // on touch-up, when the scrub is over anyway.
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) continue;
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

#pragma mark - Touch strip

// One invisible UIControl per feed RichMediaNode, covering the bottom strip of
// the video picture. Everything it needs (player, duration, the native strip's
// presence) is resolved per-touch, never cached across touches — feed players
// are created and torn down constantly as cells scroll.
@interface ApolloFeedScrubStrip : UIControl
@property (nonatomic, weak) id richMediaNode;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, strong) AVPlayer *player;              // touch-scoped
@property (nonatomic, assign) NSTimeInterval duration;       // touch-scoped
@property (nonatomic, weak) UIView *nativeStripView;         // touch-scoped
@property (nonatomic, assign) BOOL pausedForScrub;           // touch-scoped
@property (nonatomic, assign) CGFloat startX;
@property (nonatomic, assign) CFTimeInterval touchStartedAt;
@property (nonatomic, assign) BOOL didScrub;
@property (nonatomic, strong) NSArray<UIGestureRecognizer *> *suspendedGestures;
@property (nonatomic, assign) BOOL seekInFlight;
@property (nonatomic, assign) BOOL hasPendingSeek;
@property (nonatomic, assign) CMTime pendingSeekTime;
@end

static char kFeedScrubStripKey;

@implementation ApolloFeedScrubStrip

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Video progress";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}

- (void)dealloc {
    // Suspended recognizers must never outlive a touch, whatever tore us down,
    // and neither must a scrub-pause.
    RestoreCompetingGestures(_suspendedGestures);
    if (_pausedForScrub && _player) [_player play];
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
    UIView *nativeStrip = NodeIvar(self.richMediaNode, "videoGIFProgressView");
    if (![nativeStrip isKindOfClass:[UIView class]] || nativeStrip.hidden) {
        ApolloLog(@"[FeedScrubber] refusing touch: native strip %@",
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

#pragma mark Tracking

- (CGFloat)fractionForTouch:(UITouch *)touch {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return 0;
    CGFloat x = [touch locationInView:self].x;
    return MAX(0.0, MIN(1.0, x / width));
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    // Re-resolve everything: pointInside vetted the touch, but the player can
    // change between then and now (and between any two touches).
    self.player = ApolloVideoUnmute_GetPlayerFromVideoNode(self.videoNode);
    self.duration = self.player ? ScrubbableDuration(self.player) : 0;
    if (!self.player || self.duration <= 0) { self.player = nil; return NO; }

    self.startX = [touch locationInView:self].x;
    self.touchStartedAt = CACurrentMediaTime();
    self.didScrub = NO;
    self.hasPendingSeek = NO;

    // Grabbed for finger-tracking during the drag (see continueTracking).
    UIView *nativeStrip = NodeIvar(self.richMediaNode, "videoGIFProgressView");
    self.nativeStripView = [nativeStrip isKindOfClass:[UIView class]] ? nativeStrip : nil;

    // The touch only reaches us after outlasting the scroll view's touch
    // delay, so this never fires for a scrolling flick.
    self.suspendedGestures = SuspendCompetingGestures(self);
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat x = [touch locationInView:self].x;
    if (!self.didScrub) {
        if (fabs(x - self.startX) < kScrubSlop) return YES;
        self.didScrub = YES;
        // Confirms the drag reached the strip rather than being claimed by the
        // scroll view or the swipe-back pan — the failure mode to watch for.
        ApolloLog(@"[FeedScrubber] scrub engaged at %.0f%% (duration=%.1fs)",
                  [self fractionForTouch:touch] * 100.0, self.duration);
        // Pause for the duration of the drag, like every standard scrubber:
        // with playback stopped, Apollo's progress observer only fires as
        // seeks land (≈ the finger position), so it stops fighting the
        // finger-tracked bar with stale playhead widths — and the drag stops
        // playing chopped-up audio. Resumed on release/cancel, with a dealloc
        // backstop. The player is never rate-changed outside the touch.
        if (self.player.rate > 0) {
            self.pausedForScrub = YES;
            [self.player pause];
        }
    }
    CGFloat fraction = [self fractionForTouch:touch];
    [self trackFingerOnNativeStrip:fraction];
    [self scrubToFraction:fraction finished:NO];
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
    if (![fill isKindOfClass:[UIView class]] || !fill.superview) return;
    CGRect frame = fill.frame;
    frame.size.width = MAX(0.0, MIN(1.0, fraction)) * fill.superview.bounds.size.width;
    fill.frame = frame;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self restoreSuspendedGestures];

    if (self.didScrub) {
        CGFloat fraction = touch ? [self fractionForTouch:touch] : 0;
        [self scrubToFraction:fraction finished:YES];
        [self resumeIfPausedForScrub];
    } else if (CACurrentMediaTime() - self.touchStartedAt < kForwardTapMaxDuration) {
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

    self.player = nil;
    self.didScrub = NO;
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self restoreSuspendedGestures];
    [self resumeIfPausedForScrub];
    self.player = nil;
    self.didScrub = NO;
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

    // Never move the strip under the user's finger mid-scrub.
    if (strip.tracking) return;

    CGRect videoFrame = VideoContentRectInHost(videoView, host);
    if (CGRectIsEmpty(videoFrame)) return;
    CGRect stripFrame = CGRectMake(videoFrame.origin.x,
                                   CGRectGetMaxY(videoFrame) - kStripHeight,
                                   videoFrame.size.width,
                                   kStripHeight);
    strip.frame = stripFrame;
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
