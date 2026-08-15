// ApolloFeedVideoScrubber.xm
//
// "Feed Video Scrubber" — tap a playing feed video to reveal an inline scrub
// bar instead of opening the fullscreen viewer, so you can jump around a video
// without leaving the feed. Off by default (sFeedVideoScrubber).
//
//     ┌────────────────────────────────────┐
//     │                                    │
//     │            feed video              │
//     │                                    │
//     │   0:07 ──────●───────────── 0:42   │  ← our overlay (first tap)
//     └────────────────────────────────────┘
//
// Interaction model, chosen with the user to stay out of every existing
// gesture's way:
//   • FIRST tap on the video   → show the bar, swallow the tap.
//   • Tap or drag ON the bar   → seek; the auto-hide timer restarts.
//   • Tap anywhere ELSE on the video while the bar is up → hide it and open
//     the fullscreen viewer, exactly as an untouched Apollo would have on the
//     first tap. The viewer is therefore never more than two taps away.
//   • No interaction for kAutoHideDelay → the bar fades out by itself.
// A press-and-hold gesture was deliberately NOT used: long-press already owns
// the feed's context menu, and hold-on-the-right already means "play faster"
// in the fullscreen player (ApolloVideoHoldSpeed.xm).
//
// Why -[RichMediaNode didTapVideoNode:] is the interception point (recovered
// from the binary, not guessed):
//   TouchHintVideoNode is an ASVideoNode, i.e. an ASControlNode. Its tap is a
//   target/action, not a gesture recognizer. Texture's own
//   -[ASVideoNode tapped] forwards to `[self.delegate didTapVideoNode:self]`
//   when the delegate implements it, and RichMediaNode sets itself as that
//   delegate. RichMediaNode ALSO registers thumbnailTappedWithSender: on the
//   same node, but that one opens with `guard !(sender is ASVideoNode)` and
//   returns immediately for video senders, and intermediaryNodeTappedWithSender:
//   only runs while an error node is present. So didTapVideoNode: is the single
//   route from a video tap to the fullscreen viewer: its first act is to hand
//   the video node to the weak `actionDelegate` (PostCellActionTaker), which
//   presents the viewer. Skipping %orig suppresses exactly that, and nothing
//   else the user can see.
//
// Everything here is UIKit on top of a Texture node's view. RichMediaNode's own
// `videoGIFProgressView` (a plain UIVisualEffectView pinned 5pt tall to the
// bottom of the video) is hidden while our bar is up so a long video doesn't
// show two progress indicators, and restored on teardown.

#import "ApolloCommon.h"
#import "ApolloState.h"          // sFeedVideoScrubber
#import "ApolloThemeRuntime.h"   // ApolloThemeAccentColor

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Resolve the AVPlayer the same way the rest of the tweak does — the shareable
// v.redd.it path keeps its player on the playerLayer, not on the video node.
extern AVPlayer *ApolloVideoUnmute_GetPlayerFromVideoNode(id videoNode);

// Videos shorter than this aren't worth a scrub bar (and are usually silent
// GIF-style clips where the tap should just open the viewer).
static const NSTimeInterval kMinimumScrubbableDuration = 1.0;

// How long the bar stays up with no interaction.
static const NSTimeInterval kAutoHideDelay = 4.0;

// Progress refresh rate. Matches the PiP card's observer: fast enough that the
// knob tracks smoothly, slow enough to be free.
static const int32_t kProgressTimescale = 4;   // 4 Hz

static const CGFloat kOverlayHeight = 34.0;
static const CGFloat kOverlaySideInset = 8.0;
static const CGFloat kOverlayBottomInset = 6.0;
static const CGFloat kTrackHeight = 4.0;
static const CGFloat kKnobDiameter = 12.0;

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

static BOOL NodeBoolIvar(id object, const char *name) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    return *(BOOL *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
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

static NSString *FormatPlaybackTime(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
}

// Total duration in seconds, or 0 when the item is missing, still loading, or
// live/indefinite (a scrub bar over an unknown length would be a lie).
static NSTimeInterval ScrubbableDuration(AVPlayer *player) {
    AVPlayerItem *item = player.currentItem;
    if (!item) return 0;
    CMTime duration = item.duration;
    if (!CMTIME_IS_NUMERIC(duration)) return 0;
    NSTimeInterval seconds = CMTimeGetSeconds(duration);
    if (!isfinite(seconds) || seconds < kMinimumScrubbableDuration) return 0;
    return seconds;
}

#pragma mark - Scrub bar control

// A plain UIControl rather than a UISlider on purpose: on iOS 26 UIKit attaches
// a private _UIFluidSliderInteraction to every UISlider, whose continuous
// "fluid" scrub haptic buzzes the whole way through a drag (the bug chased down
// at length for the Inline Media size slider). Owning the tracking outright
// avoids that entirely and lets the touch target be taller than the track.
@interface ApolloFeedScrubBar : UIControl
@property (nonatomic, assign) CGFloat progress;        // 0…1, drives the fill
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *knobView;
@property (nonatomic, copy) void (^onScrub)(CGFloat fraction, BOOL finished);
@end

@implementation ApolloFeedScrubBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _trackView = [[UIView alloc] init];
    _trackView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.32];
    _trackView.layer.cornerRadius = kTrackHeight / 2.0;
    _trackView.userInteractionEnabled = NO;
    [self addSubview:_trackView];

    _fillView = [[UIView alloc] init];
    _fillView.layer.cornerRadius = kTrackHeight / 2.0;
    _fillView.userInteractionEnabled = NO;
    [self addSubview:_fillView];

    _knobView = [[UIView alloc] init];
    _knobView.layer.cornerRadius = kKnobDiameter / 2.0;
    _knobView.userInteractionEnabled = NO;
    _knobView.layer.shadowColor = [UIColor blackColor].CGColor;
    _knobView.layer.shadowOpacity = 0.35;
    _knobView.layer.shadowRadius = 2.0;
    _knobView.layer.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:_knobView];

    [self applyAccentColor];
    return self;
}

// The theme accent, with the documented fallback chain. Used as a plain
// backgroundColor (never .CGColor), so UIKit resolves the dynamic provider for
// the right light/dark variant on its own.
- (void)applyAccentColor {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: [UIColor systemBlueColor];
    self.fillView.backgroundColor = accent;
    self.knobView.backgroundColor = [UIColor whiteColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2.0;
    self.trackView.frame = CGRectMake(0, midY - kTrackHeight / 2.0, width, kTrackHeight);
    [self applyProgressGeometry];
}

- (void)applyProgressGeometry {
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2.0;
    CGFloat clamped = MAX(0.0, MIN(1.0, self.progress));
    self.fillView.frame = CGRectMake(0, midY - kTrackHeight / 2.0, width * clamped, kTrackHeight);
    self.knobView.frame = CGRectMake(width * clamped - kKnobDiameter / 2.0,
                                     midY - kKnobDiameter / 2.0,
                                     kKnobDiameter, kKnobDiameter);
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    [self applyProgressGeometry];
}

- (CGFloat)fractionForTouch:(UITouch *)touch {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return 0;
    CGFloat x = [touch locationInView:self].x;
    return MAX(0.0, MIN(1.0, x / width));
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.scrubbing = YES;
    CGFloat fraction = [self fractionForTouch:touch];
    self.progress = fraction;
    if (self.onScrub) self.onScrub(fraction, NO);
    [UIView animateWithDuration:0.12 animations:^{
        self.knobView.transform = CGAffineTransformMakeScale(1.35, 1.35);
    }];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat fraction = [self fractionForTouch:touch];
    self.progress = fraction;
    if (self.onScrub) self.onScrub(fraction, NO);
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.scrubbing = NO;
    CGFloat fraction = touch ? [self fractionForTouch:touch] : self.progress;
    self.progress = fraction;
    if (self.onScrub) self.onScrub(fraction, YES);
    [UIView animateWithDuration:0.12 animations:^{
        self.knobView.transform = CGAffineTransformIdentity;
    }];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    self.scrubbing = NO;
    if (self.onScrub) self.onScrub(self.progress, YES);
    [UIView animateWithDuration:0.12 animations:^{
        self.knobView.transform = CGAffineTransformIdentity;
    }];
}

@end

#pragma mark - Overlay controller

// One of these per RichMediaNode that currently shows a bar. Held by the node
// through an associated object, so it dies with the cell; -dealloc drops the
// time observer, which must never outlive the player it was added to.
@interface ApolloFeedScrubOverlay : NSObject
@property (nonatomic, weak) id richMediaNode;
@property (nonatomic, weak) id videoNode;
@property (nonatomic, strong) AVPlayer *player;          // strong: must match for removeTimeObserver:
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) ApolloFeedScrubBar *scrubBar;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, weak) UIView *nativeProgressView;  // hidden while we're up
@property (nonatomic, assign) BOOL nativeProgressWasHidden;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSUInteger hideGeneration;
@property (nonatomic, assign) BOOL seekInFlight;
@property (nonatomic, assign) BOOL hasPendingSeek;
@property (nonatomic, assign) CMTime pendingSeekTime;
@end

static char kFeedScrubOverlayKey;

@implementation ApolloFeedScrubOverlay

- (void)dealloc {
    // The observer holds the player; dropping it here covers every teardown
    // path that never got to -teardown (cell deallocated mid-scroll, etc).
    if (_timeObserver && _player) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark Build

- (void)buildInHost:(UIView *)host {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
    container.layer.cornerRadius = 10.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.userInteractionEnabled = YES;
    container.alpha = 0.0;

    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightSemibold];

    UILabel *elapsed = [[UILabel alloc] init];
    elapsed.font = font;
    elapsed.textColor = [UIColor whiteColor];
    elapsed.textAlignment = NSTextAlignmentLeft;
    [container addSubview:elapsed];

    UILabel *durationLabel = [[UILabel alloc] init];
    durationLabel.font = font;
    durationLabel.textColor = [UIColor whiteColor];
    durationLabel.textAlignment = NSTextAlignmentRight;
    [container addSubview:durationLabel];

    ApolloFeedScrubBar *bar = [[ApolloFeedScrubBar alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    bar.onScrub = ^(CGFloat fraction, BOOL finished) {
        [weakSelf scrubToFraction:fraction finished:finished];
    };
    [container addSubview:bar];

    self.container = container;
    self.scrubBar = bar;
    self.elapsedLabel = elapsed;
    self.durationLabel = durationLabel;

    [host addSubview:container];
}

// Lay the overlay along the bottom of the video, lifted clear of the mute
// button when that would otherwise sit on top of it. Frame-based on purpose:
// the host is a Texture node view laid out by frames, and this runs from show
// and from the progress tick, never from a layout callback.
- (void)positionInHost:(UIView *)host videoView:(UIView *)videoView {
    if (!host || !videoView) return;

    CGRect videoFrame = [videoView convertRect:videoView.bounds toView:host];
    if (CGRectIsEmpty(videoFrame)) return;

    CGFloat width = MAX(0.0, videoFrame.size.width - kOverlaySideInset * 2.0);
    CGFloat originX = videoFrame.origin.x + kOverlaySideInset;
    CGFloat originY = CGRectGetMaxY(videoFrame) - kOverlayHeight - kOverlayBottomInset;

    // Apollo puts the mute button in the video's bottom-right corner. Raising
    // the strip above it keeps the full track width for scrubbing AND leaves
    // the button tappable, which trimming the track's right edge would not.
    UIView *muteView = ViewForNode(NodeIvar(self.richMediaNode, "muteUnmuteButtonNode"));
    if (muteView && !muteView.hidden && muteView.alpha > 0.01) {
        CGRect muteFrame = [muteView convertRect:muteView.bounds toView:host];
        CGRect candidate = CGRectMake(originX, originY, width, kOverlayHeight);
        if (!CGRectIsEmpty(muteFrame) && CGRectIntersectsRect(candidate, muteFrame)) {
            originY = CGRectGetMinY(muteFrame) - kOverlayHeight - 4.0;
        }
    }

    // Never let it ride above the top of the video on a very short cell.
    originY = MAX(originY, videoFrame.origin.y + 2.0);

    self.container.frame = CGRectMake(originX, originY, width, kOverlayHeight);

    CGFloat labelWidth = 44.0;
    CGFloat inset = 8.0;
    self.elapsedLabel.frame = CGRectMake(inset, 0, labelWidth, kOverlayHeight);
    self.durationLabel.frame = CGRectMake(width - labelWidth - inset, 0, labelWidth, kOverlayHeight);
    CGFloat barX = inset + labelWidth + 6.0;
    CGFloat barWidth = MAX(0.0, width - barX - labelWidth - inset - 6.0);
    self.scrubBar.frame = CGRectMake(barX, 0, barWidth, kOverlayHeight);
}

#pragma mark Show / hide

- (void)showForRichMediaNode:(id)richMediaNode videoNode:(id)videoNode player:(AVPlayer *)player {
    self.richMediaNode = richMediaNode;
    self.videoNode = videoNode;
    self.player = player;
    self.duration = ScrubbableDuration(player);

    UIView *host = ViewForNode(richMediaNode);
    UIView *videoView = ViewForNode(videoNode);
    if (!host || !videoView) return;

    if (!self.container) [self buildInHost:host];
    if (self.container.superview != host) {
        [self.container removeFromSuperview];
        [host addSubview:self.container];
    }
    [host bringSubviewToFront:self.container];

    // Apollo's own 5pt progress strip would sit right under ours on long
    // videos. Park it while we're up and put it back exactly as we found it.
    UIView *nativeProgress = NodeIvar(richMediaNode, "videoGIFProgressView");
    if ([nativeProgress isKindOfClass:[UIView class]]) {
        self.nativeProgressView = nativeProgress;
        self.nativeProgressWasHidden = nativeProgress.hidden;
        nativeProgress.hidden = YES;
    }

    self.durationLabel.text = FormatPlaybackTime(self.duration);
    [self positionInHost:host videoView:videoView];
    [self refreshProgress];
    [self installTimeObserver];

    [UIView animateWithDuration:0.18 animations:^{ self.container.alpha = 1.0; }];
    [self restartAutoHide];

    ApolloLog(@"[FeedScrubber] bar shown (duration=%.1fs)", self.duration);
}

- (void)restartAutoHide {
    NSUInteger generation = ++self.hideGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoHideDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.hideGeneration != generation) return;
        if (strongSelf.scrubBar.scrubbing) { [strongSelf restartAutoHide]; return; }
        [strongSelf teardownWithReason:@"auto-hide"];
    });
}

- (void)teardownWithReason:(NSString *)reason {
    self.hideGeneration++;   // cancel any pending auto-hide

    if (self.timeObserver && self.player) {
        [self.player removeTimeObserver:self.timeObserver];
    }
    self.timeObserver = nil;

    if (self.nativeProgressView) {
        self.nativeProgressView.hidden = self.nativeProgressWasHidden;
        self.nativeProgressView = nil;
    }

    UIView *container = self.container;
    self.container = nil;
    self.scrubBar = nil;
    self.elapsedLabel = nil;
    self.durationLabel = nil;

    id owner = self.richMediaNode;
    if (owner) objc_setAssociatedObject(owner, &kFeedScrubOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [UIView animateWithDuration:0.18
                     animations:^{ container.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { [container removeFromSuperview]; }];

    ApolloLog(@"[FeedScrubber] bar hidden (%@)", reason);
}

#pragma mark Progress

- (void)installTimeObserver {
    if (self.timeObserver || !self.player) return;
    __weak typeof(self) weakSelf = self;
    self.timeObserver =
        [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, kProgressTimescale)
                                                  queue:dispatch_get_main_queue()
                                             usingBlock:^(__unused CMTime time) {
        [weakSelf tick];
    }];
}

- (void)tick {
    // Scrolled out of sight (or the cell went away): the bar has no business
    // outliving the video it belongs to, and this catches every such path
    // without a second visibility hook fighting PiP's.
    UIView *container = self.container;
    UIWindow *window = container.window;
    if (!container || !window) { [self teardownWithReason:@"off-screen"]; return; }
    CGRect inWindow = [container convertRect:container.bounds toView:nil];
    if (!CGRectIntersectsRect(inWindow, window.bounds)) {
        [self teardownWithReason:@"scrolled away"];
        return;
    }

    // Cheap re-assert: Texture can re-lay its subviews out from above, and the
    // video can resize (rotation, cell re-measure) while the bar is up.
    UIView *host = ViewForNode(self.richMediaNode);
    UIView *videoView = ViewForNode(self.videoNode);
    if (host && videoView) {
        if (container.superview != host) [host addSubview:container];
        [host bringSubviewToFront:container];
        [self positionInHost:host videoView:videoView];
    }

    if (!self.scrubBar.scrubbing) [self refreshProgress];
}

- (void)refreshProgress {
    AVPlayer *player = self.player;
    if (!player) return;
    if (self.duration <= 0) {
        // Duration can arrive after the item finishes loading.
        self.duration = ScrubbableDuration(player);
        if (self.duration > 0) self.durationLabel.text = FormatPlaybackTime(self.duration);
    }
    NSTimeInterval current = CMTimeGetSeconds([player currentTime]);
    if (!isfinite(current) || current < 0) current = 0;
    self.elapsedLabel.text = FormatPlaybackTime(current);
    if (self.duration > 0) self.scrubBar.progress = current / self.duration;
}

#pragma mark Seeking

// Chase-seek: at most one seek in flight, the newest requested position wins.
// The player is deliberately NOT paused for the drag — Apollo has several
// "snapshot the rate now, restore it later" paths (the fullscreen scrub, the
// mute dance's unpause) and a temporary rate change is exactly what made the
// hold-speed feature stick at 2x. Seeking a playing player sidesteps all of it.
- (void)scrubToFraction:(CGFloat)fraction finished:(BOOL)finished {
    [self restartAutoHide];

    AVPlayer *player = self.player;
    if (!player || self.duration <= 0) return;

    NSTimeInterval target = MAX(0.0, MIN(self.duration, self.duration * fraction));
    self.elapsedLabel.text = FormatPlaybackTime(target);

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

#pragma mark - Tap interception

// Does this video support a meaningful scrub right now?
static BOOL VideoIsScrubbable(AVPlayer *player) {
    if (!player) return NO;
    if (!player.currentItem) return NO;
    if (ScrubbableDuration(player) <= 0) return NO;
    // Only a video the user is actually watching play. A tap on a
    // paused/not-yet-started video keeps its stock meaning: open it fullscreen.
    if (player.rate > 0.0f) return YES;
    return CMTimeGetSeconds([player currentTime]) > 0.1;
}

%hook RichMediaNode

// The one route from "user tapped the feed video" to the fullscreen viewer.
// Skipping %orig suppresses the viewer for that tap and nothing else.
- (void)didTapVideoNode:(id)videoNode {
    if (!sFeedVideoScrubber) { %orig; return; }

    ApolloFeedScrubOverlay *existing = objc_getAssociatedObject(self, &kFeedScrubOverlayKey);
    if (existing) {
        // Second tap, outside the bar: put the viewer back in charge.
        [existing teardownWithReason:@"opening fullscreen"];
        %orig;
        return;
    }

    // RichMediaNode backs both the feed card and the comments header. This is
    // the "Feed Video Scrubber", and the header is a different context where a
    // tap is expected to go fullscreen, so leave that one stock.
    if (NodeBoolIvar(self, "isShownInCommentsHeader")) { %orig; return; }

    AVPlayer *player = ApolloVideoUnmute_GetPlayerFromVideoNode(videoNode);
    if (!VideoIsScrubbable(player)) { %orig; return; }

    UIView *host = ViewForNode(self);
    if (!host) { %orig; return; }

    ApolloFeedScrubOverlay *overlay = [[ApolloFeedScrubOverlay alloc] init];
    objc_setAssociatedObject(self, &kFeedScrubOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [overlay showForRichMediaNode:self videoNode:videoNode player:player];
    // %orig deliberately skipped: this tap showed the bar instead.
}

%end

%ctor {
    Class richMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    if (!richMediaNodeClass) {
        ApolloLog(@"[FeedScrubber] ctor: RichMediaNode missing - feed scrubber unavailable");
        return;
    }
    %init(RichMediaNode = richMediaNodeClass);
    ApolloLog(@"[FeedScrubber] module loaded (tap a playing feed video for a scrub bar)");
}
