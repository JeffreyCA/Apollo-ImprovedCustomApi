#import "InlineMediaSettingsViewController.h"
#import "ApolloCommon.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// MARK: - Live preview (fake comments)
//
// Same pattern as ApolloLPPreviewCardsView (Rich Link Preview settings): a
// standalone UIView owned by the controller, re-hosted into its cell on every
// cellForRow so it survives reloadData, with one apply/refresh entry point the
// controls call continuously while dragging. Frame-based layout — this is a
// plain settings view, not a Texture hook, so laying out subviews here is fine.

@interface ApolloInlineMediaPreviewView : UIView
@property (nonatomic) CGFloat mediaFraction;   // 0.5 / 0.75 / 1.0
@property (nonatomic) NSInteger alignment;     // ApolloInlineImageAlignment
@property (nonatomic) BOOL showsPlayOverlay;   // paused modes that tap-to-play

@property (nonatomic, strong) UIView *avatarOne;
@property (nonatomic, strong) UILabel *nameOne;
@property (nonatomic, strong) UIView *textBarOne;
@property (nonatomic, strong) UIView *mediaBlock;
@property (nonatomic, strong) UILabel *gifBadge;
@property (nonatomic, strong) UIImageView *playIcon;
@property (nonatomic, strong) UIView *avatarTwo;
@property (nonatomic, strong) UILabel *nameTwo;
@property (nonatomic, strong) UIView *textBarTwo;
@property (nonatomic, strong) UIView *cardBlock;
@property (nonatomic, strong) UIView *cardThumb;
@property (nonatomic, strong) UIView *cardLineOne;
@property (nonatomic, strong) UIView *cardLineTwo;
@end

@implementation ApolloInlineMediaPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _mediaFraction = 1.0;
        _alignment = ApolloInlineImageAlignmentCenter;
        [self build];
    }
    return self;
}

static UIView *ApolloIMBar(UIView *parent, CGFloat alpha) {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [[UIColor secondaryLabelColor] colorWithAlphaComponent:alpha];
    bar.layer.cornerRadius = 4.0;
    [parent addSubview:bar];
    return bar;
}

static UIView *ApolloIMAvatar(UIView *parent) {
    UIView *avatar = [[UIView alloc] init];
    avatar.backgroundColor = [UIColor systemFillColor];
    avatar.layer.cornerRadius = 12.0;
    [parent addSubview:avatar];
    return avatar;
}

static UILabel *ApolloIMName(UIView *parent, NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [parent addSubview:label];
    return label;
}

- (void)build {
    self.avatarOne = ApolloIMAvatar(self);
    self.nameOne = ApolloIMName(self, @"u/GifEnjoyer · 2h");
    self.textBarOne = ApolloIMBar(self, 0.35);

    self.mediaBlock = [[UIView alloc] init];
    self.mediaBlock.backgroundColor = [UIColor systemFillColor];
    self.mediaBlock.layer.cornerRadius = 10.0;
    self.mediaBlock.clipsToBounds = YES;
    [self addSubview:self.mediaBlock];

    self.gifBadge = [[UILabel alloc] init];
    self.gifBadge.text = @" GIF ";
    self.gifBadge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    self.gifBadge.textColor = [UIColor whiteColor];
    self.gifBadge.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    self.gifBadge.layer.cornerRadius = 4.0;
    self.gifBadge.clipsToBounds = YES;
    [self.mediaBlock addSubview:self.gifBadge];

    UIImage *play = [UIImage systemImageNamed:@"play.circle.fill"];
    self.playIcon = [[UIImageView alloc] initWithImage:play];
    self.playIcon.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    self.playIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.mediaBlock addSubview:self.playIcon];

    self.avatarTwo = ApolloIMAvatar(self);
    self.nameTwo = ApolloIMName(self, @"u/LinkLover · 1h");
    self.textBarTwo = ApolloIMBar(self, 0.35);

    self.cardBlock = [[UIView alloc] init];
    self.cardBlock.backgroundColor = [UIColor secondarySystemFillColor];
    self.cardBlock.layer.cornerRadius = 10.0;
    self.cardBlock.clipsToBounds = YES;
    [self addSubview:self.cardBlock];

    self.cardThumb = [[UIView alloc] init];
    self.cardThumb.backgroundColor = [UIColor systemFillColor];
    self.cardThumb.layer.cornerRadius = 6.0;
    [self.cardBlock addSubview:self.cardThumb];
    self.cardLineOne = ApolloIMBar(self.cardBlock, 0.5);
    self.cardLineTwo = ApolloIMBar(self.cardBlock, 0.3);
}

+ (CGFloat)preferredHeight {
    // Sized for the 100% media block on typical widths; smaller fractions
    // simply leave breathing room. Row height stays fixed so live slider
    // drags never force table reloads.
    return 384.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    if (W <= 0) return;
    CGFloat margin = 12.0;
    CGFloat rowWidth = W - margin * 2.0;
    CGFloat y = 10.0;

    self.avatarOne.frame = CGRectMake(margin, y, 24, 24);
    self.nameOne.frame = CGRectMake(margin + 32, y + 4, rowWidth - 32, 16);
    y += 32;
    self.textBarOne.frame = CGRectMake(margin, y, rowWidth * 0.86, 10);
    y += 20;

    // Media block — width follows the media slider, aspect fixed at 16:9,
    // horizontal position follows the alignment setting (same slack rule as
    // ApolloWrapImageNodeForLayout).
    CGFloat mediaWidth = MAX(60.0, rowWidth * self.mediaFraction);
    CGFloat mediaHeight = mediaWidth * 9.0 / 16.0;
    CGFloat slack = rowWidth - mediaWidth;
    CGFloat mediaX = margin + (self.alignment == ApolloInlineImageAlignmentLeft ? 0.0 :
                     self.alignment == ApolloInlineImageAlignmentRight ? slack : slack * 0.5);
    self.mediaBlock.frame = CGRectMake(mediaX, y, mediaWidth, mediaHeight);
    self.gifBadge.frame = CGRectMake(8, mediaHeight - 26, 40, 18);
    // Matches the real overlay: a small play badge pinned bottom-right.
    CGFloat playSide = 26.0;
    self.playIcon.frame = CGRectMake(mediaWidth - 6.0 - playSide, mediaHeight - 6.0 - playSide, playSide, playSide);
    self.playIcon.hidden = !self.showsPlayOverlay;
    y += mediaHeight + 18;

    self.avatarTwo.frame = CGRectMake(margin, y, 24, 24);
    self.nameTwo.frame = CGRectMake(margin + 32, y + 4, rowWidth - 32, 16);
    y += 32;
    self.textBarTwo.frame = CGRectMake(margin, y, rowWidth * 0.62, 10);
    y += 20;

    // Link preview card mock — fixed full width (card sizing is handled by the
    // Compact/Full modes in Rich Link Preview Settings, not by this screen).
    CGFloat cardWidth = rowWidth;
    CGFloat cardHeight = 72.0;
    self.cardBlock.frame = CGRectMake(margin + (rowWidth - cardWidth) * 0.5, y, cardWidth, cardHeight);
    self.cardThumb.frame = CGRectMake(8, 8, 56, 56);
    CGFloat lineX = 72.0;
    self.cardLineOne.frame = CGRectMake(lineX, 14, MAX(40.0, cardWidth - lineX - 12), 12);
    self.cardLineTwo.frame = CGRectMake(lineX, 36, MAX(30.0, (cardWidth - lineX - 12) * 0.7), 10);
}

- (void)refresh {
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

@end

// MARK: - Detent slider (50 / 75 / 100)

static NSInteger ApolloIMSnapPercent(float value) {
    if (value < 62.5f) return 50;
    if (value < 87.5f) return 75;
    return 100;
}

// The three stops and the midpoint boundaries between them (62.5, 87.5).
static const NSInteger kApolloIMStops[] = {50, 75, 100};
static const int kApolloIMStopCount = 3;

// Detent selection WITH hysteresis. The plain nearest-stop snap above flips
// the instant `raw` crosses a boundary — fine for a tap, fatal for a drag:
// a real fingertip held near a boundary jitters a pixel or two every frame
// (120Hz on ProMotion), so `raw` oscillates across the boundary and the
// caller re-fires the selection haptic each flip, producing a *continuous
// rumble* instead of one tick. (The Simulator's synthetic drags are perfectly
// smooth, so this only reproduces on device — which is why it slipped through.)
//
// Hysteresis adds a dead-band: once parked on a detent, the finger must cross
// the boundary by kApolloIMHysteresis before the detent changes. The band is
// far wider than any jitter, so a held finger stays put and the haptic fires
// exactly once per deliberate crossing. Multi-step fast drags still work — the
// loops walk as many stops as `raw` clears.
static const float kApolloIMHysteresis = 6.0f;  // percent units (range is 50)

static NSInteger ApolloIMSnapPercentHysteretic(float raw, NSInteger current) {
    int idx = 0;
    BOOL found = NO;
    for (int i = 0; i < kApolloIMStopCount; i++) {
        if (kApolloIMStops[i] == current) { idx = i; found = YES; break; }
    }
    if (!found) return ApolloIMSnapPercent(raw);   // current off-grid: hard snap
    // Move up while the finger is clearly past the upper boundary…
    while (idx < kApolloIMStopCount - 1) {
        float boundary = (kApolloIMStops[idx] + kApolloIMStops[idx + 1]) / 2.0f;
        if (raw > boundary + kApolloIMHysteresis) idx++; else break;
    }
    // …and down while clearly below the lower boundary.
    while (idx > 0) {
        float boundary = (kApolloIMStops[idx - 1] + kApolloIMStops[idx]) / 2.0f;
        if (raw < boundary - kApolloIMHysteresis) idx--; else break;
    }
    return kApolloIMStops[idx];
}

// MARK: - Swipe-back suppression while dragging the slider

// Nearest view controller for a view, via the responder chain.
static UIViewController *ApolloIMVCForView(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// A zero-slop gesture recognizer that latches to Began the instant a touch lands
// on the slider, purely to act as a FAILURE ANCHOR. Every competing swipe-back /
// transition pan is wired (once) to `requireGestureRecognizerToFail:` this
// recognizer, so a drag that STARTS on the slider can never pop the page.
//
// Why this is needed: the 50% detent's thumb sits at the far-left of the track —
// right inside the screen-edge interactive-pop zone. Dragging from there toward
// 75/100 was being stolen by Apollo's full-width swipe-back pan, which either
// popped back a screen or cancelled the slider's UIControl tracking mid-drag so
// the thumb "froze" at a detent. (The scroll-lock added earlier only stops the
// *vertical* scroll steal; the horizontal pop pan is a separate competitor that
// an earlier round wrongly assumed UIKit already excluded for controls.)
//
// This mirrors the proven requireGestureRecognizerToFail wiring in
// ApolloStatsRowTouch's magnifier loupe — UIKit's own priority primitive, so it's
// fully stateless: nothing is disabled/restored, meaning a drag that never
// delivers a clean touch-up (which happens) can't wedge swipe-back the way a
// per-drag enable/disable could. It never cancels the slider's own UIControl
// tracking (cancelsTouchesInView = NO), so scrubbing is unaffected. Because the
// anchor lives on the slider, only touches that hit the slider ever hold up the
// pop pan — swipe-back is untouched everywhere else on the screen.
@interface ApolloIMSliderClaimGesture : UIGestureRecognizer
// The single touch this anchor is bound to for the current sequence. Tracked so a
// second finger landing on the slider can't invalidly re-latch us (Changed->Began)
// or, when it lifts first, end the anchor while the scrubbing finger is still down
// — either of which would momentarily satisfy the pop pan's failure requirement
// and re-open swipe-back mid-drag. UILongPressGestureRecognizer gives the loupe
// reference this bookkeeping for free; hand-rolled here, we do it explicitly.
@property (nonatomic, weak) UITouch *claimedTouch;
@end

@implementation ApolloIMSliderClaimGesture
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.cancelsTouchesInView = NO;   // never cancel the slider's UIControl tracking
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;   // already bound — ignore extra fingers
    // A disabled (dimmed) slider must let a normal swipe-back through — only claim
    // the touch when the slider is actually interactive.
    UISlider *slider = [self.view isKindOfClass:[UISlider class]] ? (UISlider *)self.view : nil;
    if (slider && !slider.isEnabled) { self.state = UIGestureRecognizerStateFailed; return; }
    self.claimedTouch = touches.anyObject;
    self.state = UIGestureRecognizerStateBegan;   // latched — can no longer fail this touch
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Keep anchoring until OUR touch lifts — a different finger ending must not
    // release the pop-pan gate while the scrubbing finger is still down.
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    self.state = UIGestureRecognizerStateCancelled;
}
- (void)reset {
    [super reset];
    self.claimedTouch = nil;   // ready for the next sequence
}
@end

// UISlider with exactly three stops. Unlike a stock slider, tracking begins
// from a touch anywhere on the bar (not just on the thumb), and the thumb
// snaps between the detents while dragging — with a selection tick on each
// snap. Tick marks at both ends and the middle show the three positions so
// it doesn't read as a free-flowing slider.
@interface ApolloIMDetentSlider : UISlider
@property (nonatomic, strong) NSArray<UIView *> *tickViews;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
// The detent the selection haptic last fired for. Change-detection keys off
// THIS, not self.value: setValue:animated:YES leaves self.value reporting the
// mid-animation thumb position, so reading it back each continueTracking frame
// would re-trip the guard every frame and turn one tap into a continuous buzz.
@property (nonatomic) NSInteger lastSnappedPercent;
// Confirmation guard: a new detent must be seen on N consecutive tracking
// frames before it commits + fires. A single-frame (or alternating) flip — the
// signature of jitter — never accumulates the streak, so it can NEVER produce a
// haptic, whatever the underlying input pattern. Belt-and-suspenders on top of
// the hysteresis dead-band. A deliberate crossing holds the new detent for many
// frames, so it confirms in ~2 frames (imperceptible).
@property (nonatomic) NSInteger pendingPercent;
@property (nonatomic) NSInteger pendingStreak;
// Post-fire lockout: after a haptic, ignore further changes for a short window.
// Deliberate detent crossings are >150ms apart, so both fire; any residual rapid
// oscillation the streak guard misses is hard-capped to <1 tick per lockout.
@property (nonatomic) CFTimeInterval lastFireTime;
// Swipe-back suppression: the anchor gesture (added in init, lives on the slider)
// plus the weak set of pop/transition pans already wired to require it to fail, so
// re-wiring is idempotent.
@property (nonatomic, strong) ApolloIMSliderClaimGesture *claimGesture;
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *wiredBackGestures;
@end

@implementation ApolloIMDetentSlider

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSMutableArray<UIView *> *ticks = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UIView *tick = [[UIView alloc] init];
            tick.backgroundColor = [UIColor tertiaryLabelColor];
            tick.userInteractionEnabled = NO;
            tick.layer.cornerRadius = 1.0;
            // Behind the track/thumb subviews: the track covers the middle of
            // each tick, leaving the ends peeking above and below the bar.
            [self insertSubview:tick atIndex:0];
            [ticks addObject:tick];
        }
        _tickViews = ticks;
        _feedback = [[UISelectionFeedbackGenerator alloc] init];

        // Failure anchor for swipe-back suppression. nil target/action on purpose:
        // the recognizer only needs to change state (not run a callback), and a
        // self-target would retain-cycle with the view that retains it.
        _wiredBackGestures = [NSHashTable weakObjectsHashTable];
        _claimGesture = [[ApolloIMSliderClaimGesture alloc] initWithTarget:nil action:NULL];
        [self addGestureRecognizer:_claimGesture];
    }
    return self;
}

// Wire every competing swipe-back / transition pan on the ancestor chain (plus the
// nav controller's interactive pop gesture) to require the claim gesture to fail
// before it may begin. Idempotent via the weak set, so it's safe to call as the
// view enters the window AND as a drag starts — the pop pans live on the nav
// container above the settings table, which isn't reachable until we're in the
// hierarchy, and Apollo's full-width pan may be (re)installed after the push
// settles. The enclosing scroll view's own pan is spared (that steal is already
// handled by ApolloIMSettingsTableView's touchesShouldCancelInContentView:).
- (void)apollo_wireSwipeBackFailureRequirements {
    if (!self.claimGesture) return;
    NSUInteger before = self.wiredBackGestures.count;
    UIGestureRecognizer *pop = ApolloIMVCForView(self).navigationController.interactivePopGestureRecognizer;
    if (pop && ![self.wiredBackGestures containsObject:pop]) {
        [pop requireGestureRecognizerToFail:self.claimGesture];
        [self.wiredBackGestures addObject:pop];
    }
    // Walk all the way up through the window (window.superview is nil, so this
    // stops there) — a pop/transition pan can sit on the window itself, and the
    // device-proven reference wires those too. Only touches that hit the slider
    // ever hold any of these up, so wiring more is strictly safe.
    for (UIView *v = self.superview; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == self.claimGesture || g == scrollPan || g == pop) continue;
            if ([self.wiredBackGestures containsObject:g]) continue;
            NSString *cls = NSStringFromClass([g class]);
            BOOL panLike = [g isKindOfClass:[UIPanGestureRecognizer class]]
                || [cls containsString:@"ParallaxTransition"];
            if (!panLike) continue;
            [g requireGestureRecognizerToFail:self.claimGesture];
            [self.wiredBackGestures addObject:g];
        }
    }
    if (self.wiredBackGestures.count != before) {
        ApolloLog(@"[IMSlider] wired swipe-back suppression: %lu pan(s) now require the slider claim to fail (pop=%d)",
                  (unsigned long)self.wiredBackGestures.count, pop != nil);
    }
}

// iOS 26 attaches a private _UIFluidSliderInteraction to every UISlider. Its
// feedback conductor plays a CONTINUOUS "fluid" scrub haptic as the value
// modulates — a separate system from our one-tap-per-detent selectionChanged,
// and the real source of the "constant vibration while dragging" reports (our
// haptic tracer never saw it because it isn't a public UIFeedbackGenerator).
// We do our own detent tracking (UIControl beginTracking/continueTracking) and
// our own single tap, so we refuse the fluid interaction outright — this leaves
// classic UIControl tracking (still fired on device, per the logs) untouched.
- (void)addInteraction:(id<UIInteraction>)interaction {
    if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) {
        return;
    }
    [super addInteraction:interaction];
}

// Belt-and-suspenders: if a fluid interaction was already attached (added before
// we could refuse it, or via a path that bypasses addInteraction:), strip it and
// nil the private edge/modulation feedback generators when we enter a window.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    for (id<UIInteraction> ix in [self.interactions copy]) {
        if ([NSStringFromClass([ix class]) containsString:@"FluidSliderInteraction"]) {
            [self removeInteraction:ix];
        }
    }
    for (NSString *sel in @[@"_setModulationFeedbackGenerator:", @"_setEdgeFeedbackGenerator:"]) {
        SEL s = NSSelectorFromString(sel);
        if ([self respondsToSelector:s]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:s withObject:nil];
            #pragma clang diagnostic pop
        }
    }
    // Now that we're in the hierarchy, the nav container's swipe-back pans are
    // reachable — make them wait on our claim gesture.
    [self apollo_wireSwipeBackFailureRequirements];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect track = [self trackRectForBounds:self.bounds];
    const CGFloat fractions[3] = {0.0, 0.5, 1.0};
    for (NSUInteger i = 0; i < self.tickViews.count && i < 3; i++) {
        CGFloat x = CGRectGetMinX(track) + fractions[i] * CGRectGetWidth(track);
        self.tickViews[i].frame = CGRectMake(x - 1.0, CGRectGetMidY(track) - 7.0, 2.0, 14.0);
    }
}

- (void)apollo_applyTouch:(UITouch *)touch {
    CGRect track = [self trackRectForBounds:self.bounds];
    CGFloat width = MAX(1.0, CGRectGetWidth(track));
    CGFloat fraction = ([touch locationInView:self].x - CGRectGetMinX(track)) / width;
    fraction = MIN(1.0, MAX(0.0, fraction));
    float raw = self.minimumValue + fraction * (self.maximumValue - self.minimumValue);
    // Hysteretic snap keyed off the current detent — a held finger's jitter
    // can't flip it across a boundary, so the haptic fires once per crossing.
    NSInteger snapped = ApolloIMSnapPercentHysteretic(raw, self.lastSnappedPercent);

    // Confirmation streak: count consecutive frames the candidate detent differs
    // from the committed one. Only a sustained change (deliberate crossing) fires.
    if (snapped == self.lastSnappedPercent) {
        self.pendingStreak = 0;
    } else if (snapped == self.pendingPercent) {
        self.pendingStreak++;
    } else {
        self.pendingPercent = snapped;
        self.pendingStreak = 1;
    }
    CFTimeInterval now = CACurrentMediaTime();
    BOOL lockedOut = (now - self.lastFireTime) < 0.15;   // 150ms post-fire window
    BOOL confirmed = (snapped != self.lastSnappedPercent) && (self.pendingStreak >= 2) && !lockedOut;

    if (confirmed) {
        self.lastSnappedPercent = snapped;      // one haptic per confirmed crossing
        self.pendingStreak = 0;
        self.lastFireTime = now;
        [self setValue:(float)snapped animated:YES];
        [self.feedback selectionChanged];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    // Catch any pop pan installed after we entered the window (e.g. re-added when
    // the push transition settled); wiring is idempotent.
    [self apollo_wireSwipeBackFailureRequirements];
    // Sync to the settled value before the drag; self.value isn't animating yet.
    self.lastSnappedPercent = (NSInteger)lroundf(self.value);
    self.pendingPercent = self.lastSnappedPercent;
    self.pendingStreak = 0;
    [self.feedback prepare];
    [self apollo_applyTouch:touch];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self apollo_applyTouch:touch];
    return YES;
}

@end

// MARK: - Table view (keeps the slider drag from scrolling the screen)

// The settings table is isa-swizzled to this class in viewDidLoad. It overrides
// two UIScrollView touch-arbitration hooks, scoped to the size slider only, so
// the screen never scrolls out from under a slider drag — WITHOUT any per-drag
// state to enable/restore (the earlier scrollEnabled / canCancelContentTouches
// / pan-disabling approaches either collapsed the layout or left the table
// stuck when UIControl end-tracking didn't fire).
@interface ApolloIMSettingsTableView : UITableView
@end
@implementation ApolloIMSettingsTableView
static BOOL ApolloIMViewIsInSlider(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[ApolloIMDetentSlider class]]) return YES;
    }
    return NO;
}
// A touch on the slider must reach it immediately (not after the scroll-detection
// delay), or a mostly-vertical drag is claimed by the table before the slider
// ever begins tracking.
- (BOOL)touchesShouldBegin:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event inContentView:(UIView *)view {
    if (ApolloIMViewIsInSlider(view)) return YES;
    return [super touchesShouldBegin:touches withEvent:event inContentView:view];
}
// Once the slider is tracking, never cancel it to scroll — this is what stops
// the screen moving up/down during a drag. Other rows keep the default (YES),
// so normal scrolling by dragging from a row is unaffected.
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    if (ApolloIMViewIsInSlider(view)) return NO;
    return [super touchesShouldCancelInContentView:view];
}
@end

// MARK: - Controller

typedef NS_ENUM(NSInteger, ApolloIMSection) {
    ApolloIMSectionPreview = 0,
    ApolloIMSectionMaster,
    ApolloIMSectionOptions,
    ApolloIMSectionCount,
};

typedef NS_ENUM(NSInteger, ApolloIMMasterRow) {
    ApolloIMMasterRowPreviews = 0,   // inline media in posts + comments
    ApolloIMMasterRowChat,           // inline media in Chat / DMs
    ApolloIMMasterRowCount,
};

typedef NS_ENUM(NSInteger, ApolloIMOptionsRow) {
    ApolloIMOptionsRowAlignment = 0,
    ApolloIMOptionsRowAutoplay,
    ApolloIMOptionsRowMediaSize,
    ApolloIMOptionsRowCount,
};

@interface InlineMediaSettingsViewController ()
@property (nonatomic, strong) ApolloInlineMediaPreviewView *previewView;
@property (nonatomic, strong) UILabel *mediaSizeValueLabel;
@end

@implementation InlineMediaSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Inline Media";
    // Route slider-drag touch arbitration through ApolloIMSettingsTableView so a
    // drag on the size slider scrubs it instead of scrolling the screen. The
    // subclass adds no ivars, so isa-swizzling the existing table view is safe.
    if (![self.tableView isKindOfClass:[ApolloIMSettingsTableView class]]) {
        object_setClass(self.tableView, [ApolloIMSettingsTableView class]);
    }
    // Deliver slider touches immediately (the subclass's touchesShouldBegin only
    // applies while content touches are delayed; NO makes tracking begin at once
    // for a vertical drag too).
    self.tableView.delaysContentTouches = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

// MARK: Preview plumbing

- (ApolloInlineMediaPreviewView *)ensurePreviewView {
    if (!self.previewView) {
        self.previewView = [[ApolloInlineMediaPreviewView alloc] initWithFrame:CGRectZero];
    }
    [self syncPreviewState];
    return self.previewView;
}

- (void)syncPreviewState {
    self.previewView.mediaFraction = sInlineMediaSizePercent / 100.0;
    self.previewView.alignment = sInlineImageAlignment;
    NSString *mode = ApolloAutoplayGIFModeString();
    self.previewView.showsPlayOverlay = [mode isEqualToString:@"tap-to-play"];
    [self.previewView refresh];
}

// MARK: Cell helpers (repo-wide patterns — see PictureInPictureViewController)

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)valueCellLabel:(NSString *)label detail:(NSString *)detail enabled:(BOOL)enabled {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

// Slider row with a title, a live "NN%" value label, and a 50/75/100-detent
// slider underneath. The slider snaps to the three stops while dragging and
// updates the preview continuously.
- (UITableViewCell *)sliderCellLabel:(NSString *)label
                             percent:(NSInteger)percent
                             enabled:(BOOL)enabled
                              action:(SEL)action
                          valueLabel:(UILabel * __strong *)valueLabelOut {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *title = [[UILabel alloc] init];
    title.text = label;
    title.font = [UIFont systemFontOfSize:17.0];
    title.enabled = enabled;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:title];

    UILabel *value = [[UILabel alloc] init];
    value.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    value.font = [UIFont monospacedDigitSystemFontOfSize:17.0 weight:UIFontWeightRegular];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:value];
    if (valueLabelOut) *valueLabelOut = value;

    ApolloIMDetentSlider *slider = [[ApolloIMDetentSlider alloc] init];
    slider.minimumValue = 50.0;
    slider.maximumValue = 100.0;
    slider.value = (float)percent;
    slider.enabled = enabled;
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:slider];

    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
        [value.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [value.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8.0],
        [slider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [slider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6.0],
        [slider.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
    ]];
    return cell;
}

// MARK: Value strings

- (NSString *)alignmentText {
    switch (sInlineImageAlignment) {
        case ApolloInlineImageAlignmentLeft:  return @"Left";
        case ApolloInlineImageAlignmentRight: return @"Right";
        default:                              return @"Center";
    }
}

- (NSString *)autoplayModeText {
    switch (sAutoplayInlineGIFMode) {
        case ApolloAutoplayInlineGIFModeTapToPlay: return @"Tap to Play";
        case ApolloAutoplayInlineGIFModeWiFiOnly:  return @"WiFi Only";
        case ApolloAutoplayInlineGIFModeAlways:    return @"Always";
        case ApolloAutoplayInlineGIFModeNever:
        default:                                   return @"Never";
    }
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloIMSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionPreview:  return 1;
        case ApolloIMSectionMaster:   return ApolloIMMasterRowCount;
        case ApolloIMSectionOptions:  return ApolloIMOptionsRowCount;
        default:                      return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionPreview:  return @"Preview";
        case ApolloIMSectionMaster:   return @"Inline Media";
        case ApolloIMSectionOptions:  return @"Comments & Posts";
        default:                      return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionMaster:
            return @"Inline Media Previews renders image, GIF, and video links inside post text and comments instead of leaving them as plain links. Inline Media in Chat does the same for direct messages.";
        case ApolloIMSectionOptions:
            return @"Tap to Play shows a paused GIF with a play button in the bottom corner — it plays that one GIF inline and becomes a pause button, and tapping the rest of the GIF opens the fullscreen viewer as usual. Never shows a static preview (tap opens the viewer). WiFi Only autoplays on WiFi and behaves like Tap to Play on cellular.";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL inlineOn = sEnableInlineImages;
    switch (indexPath.section) {
        case ApolloIMSectionPreview: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            ApolloInlineMediaPreviewView *preview = [self ensurePreviewView];
            [preview removeFromSuperview];
            preview.frame = cell.contentView.bounds;
            preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cell.contentView addSubview:preview];
            return cell;
        }
        case ApolloIMSectionMaster:
            if (indexPath.row == ApolloIMMasterRowChat) {
                return [self switchCellLabel:@"Inline Media in Chat"
                                          on:sEnableChatMedia
                                     enabled:YES
                                      action:@selector(chatMediaSwitchToggled:)];
            }
            return [self switchCellLabel:@"Inline Media Previews"
                                      on:sEnableInlineImages
                                 enabled:YES
                                  action:@selector(inlineMediaSwitchToggled:)];
        case ApolloIMSectionOptions:
            switch (indexPath.row) {
                case ApolloIMOptionsRowAlignment:
                    return [self valueCellLabel:@"Inline Media Alignment" detail:[self alignmentText] enabled:inlineOn];
                case ApolloIMOptionsRowAutoplay:
                    return [self valueCellLabel:@"Autoplay Inline GIFs" detail:[self autoplayModeText] enabled:inlineOn];
                case ApolloIMOptionsRowMediaSize: {
                    UILabel *valueLabel = nil;
                    UITableViewCell *cell = [self sliderCellLabel:@"Inline Media Size"
                                                          percent:sInlineMediaSizePercent
                                                          enabled:inlineOn
                                                           action:@selector(mediaSizeSliderChanged:)
                                                       valueLabel:&valueLabel];
                    self.mediaSizeValueLabel = valueLabel;
                    return cell;
                }
            }
            break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloIMSectionPreview) return [ApolloInlineMediaPreviewView preferredHeight];
    if (indexPath.section == ApolloIMSectionOptions && indexPath.row == ApolloIMOptionsRowMediaSize) {
        return 88.0;
    }
    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != ApolloIMSectionOptions) return NO;
    if (!sEnableInlineImages) return NO;
    return indexPath.row == ApolloIMOptionsRowAlignment || indexPath.row == ApolloIMOptionsRowAutoplay;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ApolloIMSectionOptions || !sEnableInlineImages) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == ApolloIMOptionsRowAlignment) {
        [self presentAlignmentSheetFromSourceView:cell];
    } else if (indexPath.row == ApolloIMOptionsRowAutoplay) {
        [self presentAutoplayModeSheetFromSourceView:cell];
    }
}

// MARK: Actions

- (void)inlineMediaSwitchToggled:(UISwitch *)sw {
    sEnableInlineImages = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableInlineImages forKey:UDKeyEnableInlineImages];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloIMSectionOptions]
                  withRowAnimation:UITableViewRowAnimationNone];
}

// Master toggle for chat media (inline images/GIFs/emoji/snoomoji + working
// media sends + tap-to-fullscreen). Open chats re-render their cells on next
// display/scroll, so no immediate-refresh notification is needed. Independent
// of the posts/comments inline toggle and of Show User Profile Pictures.
- (void)chatMediaSwitchToggled:(UISwitch *)sw {
    sEnableChatMedia = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableChatMedia forKey:UDKeyEnableChatMedia];
}

- (void)mediaSizeSliderChanged:(UISlider *)slider {
    NSInteger percent = ApolloIMSnapPercent(slider.value);
    if ((NSInteger)lroundf(slider.value) != percent) [slider setValue:(float)percent animated:NO];
    self.mediaSizeValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    if (percent != sInlineMediaSizePercent) {
        sInlineMediaSizePercent = percent;
        [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:UDKeyInlineMediaSizePercent];
        // Re-measure visible comments so the change applies without leaving
        // the thread.
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloInlineMediaLayoutDidChangeNotification
                                                            object:nil];
    }
    [self syncPreviewState];
}

// MARK: Sheets

- (void)presentAlignmentSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Inline Media Alignment"
                                                                   message:@"Horizontal position of inline media narrower than the row."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *values = @[@(ApolloInlineImageAlignmentCenter),
                                    @(ApolloInlineImageAlignmentLeft),
                                    @(ApolloInlineImageAlignmentRight)];
    NSArray<NSString *> *titles = @[@"Center", @"Left", @"Right"];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSInteger value = values[i].integerValue;
        NSString *title = titles[i];
        if (sInlineImageAlignment == value) title = [title stringByAppendingString:@" (Current)"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            sInlineImageAlignment = value;
            [[NSUserDefaults standardUserDefaults] setInteger:value forKey:UDKeyInlineImageAlignment];
            // Re-measure visible comments so the change applies without
            // leaving the thread.
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloInlineMediaLayoutDidChangeNotification
                                                                object:nil];
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:ApolloIMOptionsRowAlignment
                                                                        inSection:ApolloIMSectionOptions]]
                                  withRowAnimation:UITableViewRowAnimationNone];
            [self syncPreviewState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentAutoplayModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Autoplay Inline GIFs"
                                                                   message:@"Tap to Play pauses GIFs behind a play button; tapping plays or pauses that GIF inline."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *values = @[@(ApolloAutoplayInlineGIFModeAlways),
                                    @(ApolloAutoplayInlineGIFModeWiFiOnly),
                                    @(ApolloAutoplayInlineGIFModeTapToPlay),
                                    @(ApolloAutoplayInlineGIFModeNever)];
    NSArray<NSString *> *titles = @[@"Always", @"WiFi Only", @"Tap to Play", @"Never"];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSInteger value = values[i].integerValue;
        NSString *title = titles[i];
        if (sAutoplayInlineGIFMode == value) title = [title stringByAppendingString:@" (Current)"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            sAutoplayInlineGIFMode = value;
            // The KVO observer in ApolloMediaAutoplay picks this write up and
            // refreshes every registered on-screen GIF immediately.
            [[NSUserDefaults standardUserDefaults] setInteger:value forKey:UDKeyAutoplayInlineGIFs];
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:ApolloIMOptionsRowAutoplay
                                                                        inSection:ApolloIMSectionOptions]]
                                  withRowAnimation:UITableViewRowAnimationNone];
            [self syncPreviewState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
