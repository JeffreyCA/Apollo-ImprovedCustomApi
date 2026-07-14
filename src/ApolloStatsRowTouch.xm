// ApolloStatsRowTouch
//
// Makes the little "info row" under a post/comment (score · comments · age …)
// easier to use. Two pieces:
//
//   1. Tap-comments-to-jump (always on — tapping the bubble is an unambiguous
//      "take me to the comments"; tapping anywhere else on the post still opens
//      the thread at the top as normal)
//      Tapping the comment-count bubble in a *feed* post already opens the post,
//      but it lands at the very top (title + media). Here we detect that the tap
//      landed on the comment bubble and, once the pushed CommentsViewController
//      appears, scroll it so the post's action bar (up/down/reply/share) sits just
//      under the nav bar — the "Discussion so far" summary and the comments follow
//      right below it. The bubble also gets a comfortable tap target.
//
//   2. Press-and-hold magnifier (sIconRowMagnifier) — added in a later section.
//
// Design notes:
//   * The info-row buttons (pointsButtonNode / commentsInfoNode / ageButtonNode)
//     live on PostInfoNode, which the feed cells embed as `postInfoNode`. They are
//     layer-backed and rasterized, so we can't rely on per-node targets; instead
//     we install ONE gesture on the cell's own (always view-backed) view and
//     hit-test the embedded node's CALayer — the same proven approach as
//     ApolloCreatedAtAlert (which owns the *age* tap).
//   * ApolloCreatedAtAlert already defines -gestureRecognizer:shouldReceiveTouch:
//     on these same cell classes, so we must NOT add a second one (Logos %new
//     collision). We route our gesture through a shared singleton delegate object
//     instead, keeping the two modules independent and their hit regions disjoint
//     (age owns the rightmost node; we own the comment bubble to its left).
//   * The comment gesture is deliberately NON-consuming (cancelsTouchesInView=NO):
//     Apollo's native tableView:didSelectRowAtIndexPath: still fires and opens the
//     post; we only set a short-lived "jump pending" flag that the comments view
//     consumes on appear.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloCreatedAtAlert.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UIWindow+Apollo.h"

// MARK: - Minimal AsyncDisplayKit forward declarations

@interface ApolloSRTNode : UIResponder
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, getter=isHidden) BOOL hidden;
@end

// RDKLink / RDKComment expose a `createdUTC` NSDate (used for the "Posted … Ago"
// alert); declared informally so we can message any post model.
@interface NSObject (ApolloSRTCreatedAt)
- (NSDate *)createdUTC;
@end

// MARK: - Runtime ivar helpers

static id SRTIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static NSTimeInterval SRTNow(void) {
    return [NSDate date].timeIntervalSinceReferenceDate;
}

// The comment-count node for a feed cell: cell.postInfoNode.commentsInfoNode.
static ApolloSRTNode *SRTCommentsNodeForCell(id cell) {
    id postInfoNode = SRTIvar(cell, "postInfoNode");
    if (!postInfoNode) return nil;
    return (ApolloSRTNode *)SRTIvar(postInfoNode, "commentsInfoNode");
}

// YES if `touch` falls inside `node`'s layer (in cellView coords), expanded by
// `insets` (top,left,bottom,right; negative = grow). Works for layer-backed nodes.
static BOOL SRTTouchHitsNode(ApolloSRTNode *node, UIView *cellView, UITouch *touch, UIEdgeInsets insets) {
    if (!node || node.isHidden || !cellView) return NO;
    CALayer *layer = nil;
    @try { layer = node.layer; } @catch (__unused id e) {}
    if (!layer || !cellView.layer) return NO;
    CGRect rect = [layer convertRect:layer.bounds toLayer:cellView.layer];
    if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || CGRectIsInfinite(rect)) return NO;
    rect = UIEdgeInsetsInsetRect(rect, insets);
    CGPoint pt = [touch locationInView:cellView];
    return CGRectContainsPoint(rect, pt);
}

// MARK: - "Jump to comments" pending flag (set on bubble tap, consumed on appear)

// A feed tap → push is near-instant; the comments view's viewDidAppear fires a
// few hundred ms later. A short deadline covers that window and self-expires so a
// stray tap never mis-fires on the next post you open normally.
static const NSTimeInterval kSRTJumpTTL = 2.5;
static NSTimeInterval gSRTJumpPendingDeadline = 0;

static void SRTArmJumpPending(void) {
    gSRTJumpPendingDeadline = SRTNow() + kSRTJumpTTL;
}

// Consume: returns YES at most once per arm, and only while fresh.
static BOOL SRTConsumeJumpPending(void) {
    BOOL pending = (gSRTJumpPendingDeadline > SRTNow());
    gSRTJumpPendingDeadline = 0;
    return pending;
}

// MARK: - Magnifier loupe: stat-target model

typedef NS_ENUM(NSInteger, SRTStatKind) {
    SRTStatKindScore = 0,     // release = upvote (the ↑ icon)
    SRTStatKindPercentage,    // release = "% Upvoted" detail (Popup/Overlay mode)
    SRTStatKindComments,      // release = open post at the comment section
    SRTStatKindAge,           // release = "Posted … Ago" detail (Popup/Overlay mode)
    SRTStatKindEdited,        // release = "Edited … Ago" detail (Popup/Overlay mode)
    SRTStatKindTranslation,   // release = toggle title translated ⇄ original
};

@interface ApolloSRTTarget : NSObject
@property (nonatomic, assign) SRTStatKind kind;
@property (nonatomic, assign) CGRect rect;      // in cellView coords
@property (nonatomic, copy) NSString *caption;
@property (nonatomic, weak) UILabel *markerLabel;   // translation targets only
@end
@implementation ApolloSRTTarget
@end

// Per-icon activation check (Info Row settings sub-screen). Disabled icons STILL
// appear in the loupe (see SRTTargetsForCell) — this only gates what happens on
// RELEASE: a disabled kind does nothing. The three "info" icons (% upvoted, age,
// edited) share the Popup/Overlay mode: enabled if either mode is on.
static BOOL SRTKindTapEnabled(SRTStatKind kind) {
    switch (kind) {
        case SRTStatKindScore:       return sInfoRowTapUpvote;
        case SRTStatKindComments:    return sInfoRowTapComments;
        case SRTStatKindPercentage:  return sInfoRowPopupMode || sInfoRowOverlayMode;
        case SRTStatKindAge:         return sInfoRowPopupMode || sInfoRowOverlayMode;
        case SRTStatKindEdited:      return sInfoRowPopupMode || sInfoRowOverlayMode;
        case SRTStatKindTranslation: return sInfoRowTapTranslation;
    }
    return YES;
}

// The translation module (ApolloTranslation.xm — actively developed in its own
// workstream, so we only *look at* its artifacts, never call its internals
// directly) overlays a compact "🌐 PT" UILabel inside the PostInfoNode subtree
// (a child of the age node's view, or of the PostInfoNode view as fallback).
// Find it structurally: Apollo renders all of its own stats through Texture
// text layers — never UILabels — so a short, visible UILabel in this subtree IS
// the marker. Do NOT match on the "🌐" character: the globe is an
// NSTextAttachment image, not text. Returns nil when the post has no marker.
static UILabel *SRTTranslationMarkerLabel(id postInfoNode) {
    UIView *piView = nil;
    @try { piView = [(ApolloSRTNode *)postInfoNode view]; } @catch (__unused id e) {}
    if (!piView) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:piView];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            NSUInteger len = l.attributedText.length ?: l.text.length;
            if (!l.hidden && l.alpha > 0.01 && len > 0 && len <= 8) return l;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// Enumerate the visible info-row stat targets on a cell, ordered left-to-right.
// Feed cells carry score/comments/age (+ optional 🌐 translation marker); the
// comments header carries score/%/age (+ marker).
static NSArray<ApolloSRTTarget *> *SRTTargetsForCell(id cell, UIView *cellView) {
    id postInfoNode = SRTIvar(cell, "postInfoNode");
    if (!postInfoNode || !cellView || !cellView.layer) return @[];
    const struct { const char *ivar; SRTStatKind kind; __unsafe_unretained NSString *caption; } specs[] = {
        {"pointsButtonNode",           SRTStatKindScore,      @"Upvote"},
        {"percentageLikedButtonNode",  SRTStatKindPercentage, @"% Upvoted"},
        {"commentsInfoNode",           SRTStatKindComments,   @"Comments"},
        {"ageButtonNode",              SRTStatKindAge,        @"Posted"},
        {"editedButtonNode",           SRTStatKindEdited,     @"Edited"},
    };
    NSMutableArray<ApolloSRTTarget *> *out = [NSMutableArray array];
    for (int i = 0; i < (int)(sizeof(specs) / sizeof(specs[0])); i++) {
        // Disabled icons still APPEAR in the loupe (the user can slide over them);
        // releasing on one just does nothing — gated in SRTActivateTarget, not here.
        ApolloSRTNode *node = (ApolloSRTNode *)SRTIvar(postInfoNode, specs[i].ivar);
        if (!node || node.isHidden) continue;
        CALayer *layer = nil; @try { layer = node.layer; } @catch (__unused id e) {}
        if (!layer) continue;
        CGRect rect = [layer convertRect:layer.bounds toLayer:cellView.layer];
        if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || CGRectIsInfinite(rect)) continue;
        if (rect.size.width < 1.0 || rect.size.height < 1.0) continue;
        ApolloSRTTarget *t = [ApolloSRTTarget new];
        t.kind = specs[i].kind; t.rect = rect; t.caption = specs[i].caption;
        [out addObject:t];
    }
    // Optional 🌐 translation marker (a UILabel overlaid by the translation module).
    // Always shown in the loupe when present; activation is gated in SRTActivateTarget.
    UILabel *marker = SRTTranslationMarkerLabel(postInfoNode);
    if (marker && marker.layer && cellView.layer) {
        CGRect rect = [marker.layer convertRect:marker.layer.bounds toLayer:cellView.layer];
        if (!CGRectIsEmpty(rect) && !CGRectIsNull(rect) && !CGRectIsInfinite(rect) && rect.size.width >= 1.0) {
            ApolloSRTTarget *t = [ApolloSRTTarget new];
            t.kind = SRTStatKindTranslation; t.rect = rect; t.caption = @"Translate"; t.markerLabel = marker;
            [out addObject:t];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(ApolloSRTTarget *a, ApolloSRTTarget *b) {
        return a.rect.origin.x < b.rect.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

// The strip = union of the visible target rects, padded, in cellView coords.
// (Used for the loupe snapshot — what gets magnified.)
static CGRect SRTStripRect(NSArray<ApolloSRTTarget *> *targets) {
    if (targets.count == 0) return CGRectNull;
    CGRect u = targets.firstObject.rect;
    for (ApolloSRTTarget *t in targets) u = CGRectUnion(u, t.rect);
    return CGRectInset(u, -8.0, -9.0);
}

// The claim = where a press-and-hold belongs to the magnifier (and the context
// menu is suppressed). Fatter than the strip, but tight against neighbours:
// reaches the screen edge only when the ↑ actually hugs the margin (in compact
// layouts the thumbnail/username share the line), stays clear of the ••• past
// the last icon, and pads generously below but only slightly above (the
// username/subreddit line sits right on top of the row).
static CGRect SRTClaimRect(id cell, UIView *cellView, NSArray<ApolloSRTTarget *> *targets) {
    if (targets.count == 0) return CGRectNull;
    CGRect u = targets.firstObject.rect;
    for (ApolloSRTTarget *t in targets) u = CGRectUnion(u, t.rect);

    CGFloat minX = CGRectGetMinX(u);
    CGFloat left = (minX <= 28.0) ? 0.0 : minX - 12.0;   // screen edge only when the row starts there
    CGFloat right = CGRectGetMaxX(u) + 10.0;
    CGFloat top = CGRectGetMinY(u) - 6.0;
    CGFloat bottom = CGRectGetMaxY(u) + 20.0;

    // Feed cells: the row is the cell's last line — claim the trailing padding.
    static Class headerClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ headerClass = NSClassFromString(@"_TtC6Apollo22CommentsHeaderCellNode"); });
    BOOL isHeader = headerClass && [cell isKindOfClass:headerClass];
    CGFloat cellBottom = CGRectGetHeight(cellView.bounds);
    if (!isHeader && cellBottom - CGRectGetMaxY(u) < 44.0) bottom = cellBottom;

    // Comfort height is gained downward only (above is the username line).
    if (bottom - top < 44.0) bottom = top + 44.0;
    return CGRectMake(left, top, right - left, bottom - top);
}

// X-axis distance from x to rect's horizontal span (0 when within it).
static CGFloat SRTXEdgeDistance(CGRect rect, CGFloat x) {
    if (x < CGRectGetMinX(rect)) return CGRectGetMinX(rect) - x;
    if (x > CGRectGetMaxX(rect)) return x - CGRectGetMaxX(rect);
    return 0.0;
}

// Neighbours rendered by PostInfoNode that are NOT loupe territory: the
// subreddit/author line and the ••• button. Containment alone can't decide —
// node rects run much bigger than their glyphs (the author line often spans
// the whole stats row below it) — so a neighbour's grown rect only NOMINATES
// the press and proximity decides, ties going to the loupe: on its own line,
// the vertically nearer midline wins (crossover = mid-gap); on the stats line
// (•••), the nearer horizontal span wins.
static BOOL SRTPointOnExcludedNeighbour(id cell, UIView *cellView, NSArray<ApolloSRTTarget *> *targets, CGPoint pt) {
    id postInfoNode = SRTIvar(cell, "postInfoNode");
    if (!postInfoNode || !cellView.layer || targets.count == 0) return NO;
    CGRect u = targets.firstObject.rect;
    for (ApolloSRTTarget *t in targets) u = CGRectUnion(u, t.rect);
    CGFloat statsMidY = CGRectGetMidY(u);
    static const char *neighbours[] = {
        "subredditIconNode", "subredditButtonNode", "authorButtonNode",
        "flairNode", "cakedayNode", "moreOptionsButtonNode",
    };
    for (size_t i = 0; i < sizeof(neighbours) / sizeof(neighbours[0]); i++) {
        ApolloSRTNode *node = (ApolloSRTNode *)SRTIvar(postInfoNode, neighbours[i]);
        if (!node || node.isHidden) continue;
        CALayer *layer = nil;
        @try { layer = node.layer; } @catch (__unused id e) {}
        if (!layer) continue;
        CGRect rect = [layer convertRect:layer.bounds toLayer:cellView.layer];
        if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || CGRectIsInfinite(rect)) continue;
        CGRect grown = UIEdgeInsetsInsetRect(rect, (UIEdgeInsets){-4.0, -4.0, -8.0, -4.0});
        if (!CGRectContainsPoint(grown, pt)) continue;
        if (fabs(CGRectGetMidY(rect) - statsMidY) > 8.0) {
            // Own line above the stats: vertical midline proximity decides.
            if (fabs(pt.y - CGRectGetMidY(rect)) < fabs(pt.y - statsMidY)) return YES;
        } else {
            // On the stats line: nearer horizontal span decides.
            CGFloat statDist = CGFLOAT_MAX;
            for (ApolloSRTTarget *t in targets) statDist = MIN(statDist, SRTXEdgeDistance(t.rect, pt.x));
            if (SRTXEdgeDistance(rect, pt.x) < statDist) return YES;
        }
    }
    return NO;
}

// Single source of truth for both the gesture's touch gating and the
// context-menu suppression: inside the claim and not on an excluded neighbour.
static BOOL SRTPointClaimedForLoupe(id cell, UIView *cellView, NSArray<ApolloSRTTarget *> *targets, CGPoint pt) {
    CGRect claim = SRTClaimRect(cell, cellView, targets);
    if (CGRectIsNull(claim) || !CGRectContainsPoint(claim, pt)) return NO;
    return !SRTPointOnExcludedNeighbour(cell, cellView, targets, pt);
}

// Nearest target to a point's X (Voronoi on centers). Fills the gaps so every
// spot in the strip picks exactly one icon.
static NSInteger SRTNearestTargetIndex(NSArray<ApolloSRTTarget *> *targets, CGFloat x) {
    NSInteger best = 0; CGFloat bestDist = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)targets.count; i++) {
        CGFloat cx = CGRectGetMidX(targets[i].rect);
        CGFloat d = fabs(cx - x);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

// MARK: - Magnifier loupe: view

// The "glass slider" loupe: a floating Liquid Glass card showing the icon row
// zoomed, with an accent pill that springs from icon to icon as the finger
// slides. Uses UIGlassEffect when the app runs with Liquid Glass, otherwise a
// system blur — same layout either way. Dragging well away from the row dims
// the card into "Release to Cancel" (releasing there activates nothing);
// sliding back re-engages.
@interface ApolloSRTLoupeView : UIView
@property (nonatomic, strong) UIVisualEffectView *card;
@property (nonatomic, strong) UIImageView *stripImageView;
@property (nonatomic, strong) UIView *highlightView;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, assign) CGFloat zoom;
@property (nonatomic, assign) CGSize stripPointSize;   // strip size in points
@property (nonatomic, assign) BOOL hasSelection;       // NO until the first selectRect
@property (nonatomic, assign) CGFloat lockedCenterY;   // 0 until first placement, then fixed
- (instancetype)initWithImage:(UIImage *)img stripSize:(CGSize)stripSize zoom:(CGFloat)zoom;
- (void)selectRect:(CGRect)rectInStrip caption:(NSString *)caption tint:(UIColor *)tint;
- (void)positionAboveScreenPoint:(CGPoint)p inHost:(UIView *)host;
- (void)setCancelledAppearance:(BOOL)cancelled;
@end

@implementation ApolloSRTLoupeView

- (instancetype)initWithImage:(UIImage *)img stripSize:(CGSize)stripSize zoom:(CGFloat)zoom {
    CGFloat pad = 10.0, captionH = 16.0, gap = 4.0;
    CGFloat imgW = stripSize.width * zoom;
    CGFloat imgH = stripSize.height * zoom;
    CGSize cardSize = CGSizeMake(imgW + pad * 2.0, imgH + pad * 2.0 + gap + captionH);
    if ((self = [super initWithFrame:CGRectMake(0, 0, cardSize.width, cardSize.height)])) {
        self.zoom = zoom;
        self.stripPointSize = stripSize;
        self.userInteractionEnabled = NO;

        // Material: real glass on iOS 26 (matches the nav-bar look), blur fallback.
        UIVisualEffect *effect = nil;
        Class glassCls = NSClassFromString(@"UIGlassEffect");
        if (IsLiquidGlass() && glassCls) {
            effect = [[glassCls alloc] init];
        } else {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        }
        _card = [[UIVisualEffectView alloc] initWithEffect:effect];
        _card.frame = self.bounds;
        _card.layer.cornerRadius = cardSize.height / 2.0 > 26.0 ? 22.0 : cardSize.height / 2.0;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.clipsToBounds = YES;
        [self addSubview:_card];

        // Soft drop shadow lives on the wrapper (the card clips its own bounds).
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 16.0;
        self.layer.shadowOffset = CGSizeMake(0, 8);
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                           cornerRadius:_card.layer.cornerRadius].CGPath;

        // Rounded clip container for the zoomed strip.
        UIView *clip = [[UIView alloc] initWithFrame:CGRectMake(pad, pad, imgW, imgH)];
        clip.layer.cornerRadius = 10.0;
        clip.layer.cornerCurve = kCACornerCurveContinuous;
        clip.clipsToBounds = YES;
        [_card.contentView addSubview:clip];

        // Selection pill UNDER the strip pixels: tints the icon without washing it out.
        _highlightView = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightView.layer.cornerRadius = 8.0;
        _highlightView.layer.cornerCurve = kCACornerCurveContinuous;
        _highlightView.layer.borderWidth = 1.5;
        [clip addSubview:_highlightView];

        _stripImageView = [[UIImageView alloc] initWithFrame:clip.bounds];
        _stripImageView.image = img;
        _stripImageView.contentMode = UIViewContentModeScaleToFill;
        [clip addSubview:_stripImageView];

        // Pill border redrawn ABOVE the strip so the outline stays crisp.
        UIView *ring = [[UIView alloc] initWithFrame:CGRectZero];
        ring.layer.cornerRadius = 8.0;
        ring.layer.cornerCurve = kCACornerCurveContinuous;
        ring.layer.borderWidth = 1.5;
        ring.backgroundColor = [UIColor clearColor];
        ring.tag = 0x5254;   // 'RT' — looked up in selectRect
        [clip addSubview:ring];

        _captionLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, imgH + pad + gap, imgW, captionH)];
        _captionLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _captionLabel.textColor = [UIColor labelColor];
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        [_card.contentView addSubview:_captionLabel];
    }
    return self;
}

// rectInStrip is in strip-local point coords; tint is the accent color. The pill
// springs to the new icon; the first call places it without animation.
- (void)selectRect:(CGRect)rectInStrip caption:(NSString *)caption tint:(UIColor *)tint {
    CGRect scaled = CGRectMake(rectInStrip.origin.x * self.zoom, rectInStrip.origin.y * self.zoom,
                               rectInStrip.size.width * self.zoom, rectInStrip.size.height * self.zoom);
    // Comfortable pill around the icon.
    scaled = CGRectInset(scaled, -7.0, -5.0);
    UIView *ring = [self.highlightView.superview viewWithTag:0x5254];
    void (^apply)(void) = ^{
        self.highlightView.frame = scaled;
        ring.frame = scaled;
    };
    self.highlightView.backgroundColor = [tint colorWithAlphaComponent:0.28];
    self.highlightView.layer.borderColor = [UIColor clearColor].CGColor;
    ring.layer.borderColor = [tint colorWithAlphaComponent:0.9].CGColor;
    // The strip snapshot is opaque, so the under-fill can't show through — give the
    // ring itself a soft tint wash so the selected icon reads as "lit up".
    ring.backgroundColor = [tint colorWithAlphaComponent:0.16];
    if (!self.hasSelection) {
        self.hasSelection = YES;
        apply();
    } else {
        // Springy glass-slider glide between icons.
        [UIView animateWithDuration:0.28 delay:0
             usingSpringWithDamping:0.75 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    }
    self.captionLabel.text = caption;
}

// Drag-away-to-cancel state: dim + shrink the card, hide the selection pill, and
// caption the escape hatch. Fully reversible — sliding back re-engages (selectRect
// restores the caption and the pill springs back to the nearest icon).
- (void)setCancelledAppearance:(BOOL)cancelled {
    UIView *ring = [self.highlightView.superview viewWithTag:0x5254];
    if (cancelled) self.captionLabel.text = @"Release to Cancel";
    [UIView animateWithDuration:0.18 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.alpha = cancelled ? 0.45 : 1.0;
        self.transform = cancelled ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
        self.highlightView.alpha = cancelled ? 0.0 : 1.0;
        ring.alpha = cancelled ? 0.0 : 1.0;
    } completion:nil];
}

// Center horizontally on p.x (clamped). The VERTICAL position is anchored above
// the initial press and then LOCKED — following the finger's y while sliding
// across the row made the card bob up and down (jittery). Uses center (not
// frame) so it stays correct while the show/hide scale transform is applied.
- (void)positionAboveScreenPoint:(CGPoint)p inHost:(UIView *)host {
    CGFloat margin = 10.0;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat cx = MAX(margin + w / 2.0, MIN(p.x, host.bounds.size.width - margin - w / 2.0));
    if (self.lockedCenterY == 0.0) {            // first placement: anchor, then lock
        CGFloat topInset = host.safeAreaInsets.top + 6.0;
        CGFloat top = p.y - h - 44.0;           // clear of the finger/cursor
        if (top < topInset) top = p.y + 44.0;   // not enough room above -> below the finger
        self.lockedCenterY = top + h / 2.0;
    }
    self.center = CGPointMake(cx, self.lockedCenterY);
}

@end

// MARK: - Magnifier: activation (open post / vote / info detail)

// The % upvoted / age / edited details are presented via ApolloCreatedAtAlert's
// ApolloPresentInfoDetail (see SRTActivateTarget), so the loupe matches the
// direct taps and there's no duplicate alert/overlay/date code here.

static UIViewController *SRTVisibleVCForView(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// Open the post the same way a tap would: replay Apollo's own row selection. When
// `jump` is set, arm the jump-to-comments flag first so it lands on the comments.
static void SRTOpenPostForCell(id cell, UIView *cellView, BOOL jump) {
    if (!cellView) return;
    UITableView *tv = nil;
    for (UIView *v = cellView; v; v = v.superview) {
        if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
    }
    if (!tv) return;
    NSIndexPath *ip = nil;
    for (UIView *v = cellView; v && v != tv; v = v.superview) {
        if ([v isKindOfClass:[UITableViewCell class]]) { ip = [tv indexPathForCell:(UITableViewCell *)v]; break; }
    }
    if (!ip) {
        CGPoint c = [cellView convertPoint:CGPointMake(CGRectGetMidX(cellView.bounds), CGRectGetMidY(cellView.bounds)) toView:tv];
        ip = [tv indexPathForRowAtPoint:c];
    }
    if (!ip) return;
    if (jump) SRTArmJumpPending();
    SEL sel = @selector(tableView:didSelectRowAtIndexPath:);
    id delegate = tv.delegate;
    if ([delegate respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, tv, ip);
        return;
    }
    UIViewController *vc = SRTVisibleVCForView(cellView);
    if ([vc respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(vc, sel, tv, ip);
    }
}

// The cell's real upvote control, wherever this cell type keeps it:
//   LargePostCellNode:      optionButtonsNode.upvoteButton
//   CompactPostCellNode:    upvoteButtonNode (directly on the cell)
//   CommentsHeaderCellNode: quickBarNode.upvoteButton
static id SRTUpvoteButtonForCell(id cell) {
    id direct = SRTIvar(cell, "upvoteButtonNode");
    if (direct) return direct;
    id optionButtons = SRTIvar(cell, "optionButtonsNode");
    id fromOptions = optionButtons ? SRTIvar(optionButtons, "upvoteButton") : nil;
    if (fromOptions) return fromOptions;
    id quickBar = SRTIvar(cell, "quickBarNode");
    return quickBar ? SRTIvar(quickBar, "upvoteButton") : nil;
}

// Fire the button's own action exactly like a tap: ASControlNode event
// TouchUpInside (1 << 4). Goes through Apollo's real vote path (state, API,
// arrow color), so it stays correct across app versions.
static BOOL SRTSendTouchUpInside(id controlNode) {
    SEL sel = NSSelectorFromString(@"sendActionsForControlEvents:withEvent:");
    if (!controlNode || ![controlNode respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(controlNode, sel, (NSUInteger)(1 << 4), nil);
    return YES;
}

// Toggle the post title translated ⇄ original through the translation module's
// own tap target (ApolloTranslation.xm). Runtime-bridged so this module never
// links against that one: shared.pendingLabel = marker; handleCellTap:nil.
static BOOL SRTToggleTranslationForMarker(UILabel *marker) {
    if (!marker) return NO;
    Class cls = NSClassFromString(@"ApolloFeedMarkerTapTarget");
    if (!cls || ![cls respondsToSelector:@selector(shared)]) return NO;
    id shared = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(shared));
    SEL setSel = NSSelectorFromString(@"setPendingLabel:");
    SEL tapSel = NSSelectorFromString(@"handleCellTap:");
    if (![shared respondsToSelector:setSel] || ![shared respondsToSelector:tapSel]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(shared, setSel, marker);
    ((void (*)(id, SEL, id))objc_msgSend)(shared, tapSel, nil);
    return YES;
}

static void SRTActivateTarget(id cell, UIView *cellView, ApolloSRTTarget *target) {
    if (!target) return;
    if (!SRTKindTapEnabled(target.kind)) return;   // defensive: disabled kinds never reach here
    switch (target.kind) {
        case SRTStatKindScore: {
            if (!SRTSendTouchUpInside(SRTUpvoteButtonForCell(cell))) {
                // No reachable vote control on this cell type — open the post instead.
                SRTOpenPostForCell(cell, cellView, /*jump=*/NO);
            }
            break;
        }
        case SRTStatKindComments:
            SRTOpenPostForCell(cell, cellView, /*jump=*/YES);
            break;
        case SRTStatKindPercentage:
        case SRTStatKindAge:
        case SRTStatKindEdited: {
            // The three "info" icons share ApolloCreatedAtAlert's presenter, so the
            // loupe matches the direct tap (Popup alert or Overlay per the mode).
            ApolloInfoKind ik = target.kind == SRTStatKindPercentage ? ApolloInfoKindPercentage
                              : target.kind == SRTStatKindEdited      ? ApolloInfoKindEdited
                                                                      : ApolloInfoKindAge;
            id link = SRTIvar(cell, "link");
            id comment = SRTIvar(cell, "comment");
            UIWindow *window = cellView.window;
            CGRect anchor = window ? [cellView convertRect:target.rect toView:nil] : CGRectNull;
            ApolloPresentInfoDetail(ik, link, comment, cellView, anchor, window);
            break;
        }
        case SRTStatKindTranslation:
            SRTToggleTranslationForMarker(target.markerLabel);
            break;
    }
}

// MARK: - Shared gesture delegate (comment bubble + magnifier)

// Marker/back-ref keys stored on the gesture recognizer.
static const void *kSRTCommentGestureCellKey = &kSRTCommentGestureCellKey;   // ASSIGN: owning cell node
static const void *kSRTCommentGestureInstalledKey = &kSRTCommentGestureInstalledKey; // RETAIN on cell: idempotency
static const void *kSRTGestureTypeKey = &kSRTGestureTypeKey;   // NSNumber: 1=comment tap, 2=loupe long-press
// Per-loupe-gesture live state.
static const void *kSRTLoupeViewKey = &kSRTLoupeViewKey;       // RETAIN: current ApolloSRTLoupeView
static const void *kSRTLoupeTargetsKey = &kSRTLoupeTargetsKey; // RETAIN: NSArray<ApolloSRTTarget*>
static const void *kSRTLoupeStripOriginKey = &kSRTLoupeStripOriginKey; // NSValue CGPoint: strip origin in cell coords
static const void *kSRTLoupeSelKey = &kSRTLoupeSelKey;         // NSNumber: selected index
static const void *kSRTLoupeScrollLockKey = &kSRTLoupeScrollLockKey; // RETAIN: UIScrollView we disabled while the loupe is up
static const void *kSRTLoupeCancelKey = &kSRTLoupeCancelKey;   // NSNumber BOOL: finger dragged away — release cancels
static const void *kSRTLoupeTouchStartKey = &kSRTLoupeTouchStartKey; // NSValue CGPoint: touch-down point (window coords)
static const void *kSRTLoupeTintKey = &kSRTLoupeTintKey;       // RETAIN: accent resolved once per hold

enum { kSRTGestureTypeCommentTap = 1, kSRTGestureTypeLoupe = 2 };

// Comfortable hit region for the comment bubble. Asymmetric: a touch more room
// toward the age node on the right (where taps are meant to distinguish the two)
// and vertically (the row is thin), a little less toward the score on the left.
static const UIEdgeInsets kSRTCommentInsets = (UIEdgeInsets){ -11.0, -7.0, -11.0, -9.0 };

@interface ApolloSRTGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

// Snapshot the strip region (the info row) into an image for the loupe.
//
// We render from the WINDOW, not the cell: on a very long post the comments-header
// cell's own bounds are enormous (thousands of points), and drawing them with
// drawViewHierarchyInRect comes back blank (the off-screen expanse blows past the
// snapshot's texture budget) — which is exactly the "magnifier icons are blank on
// long posts" bug. The window is always screen-sized and the info row is visible
// in it while you hold, so snapshotting the window's strip region is reliable
// regardless of how tall the cell is. `hideDuringSnapshot` (the loupe, on the
// re-snapshot) is momentarily hidden so it can't capture itself over the icons.
static UIImage *SRTSnapshotStrip(UIView *cellView, CGRect stripRect, UIView *hideDuringSnapshot) {
    if (stripRect.size.width < 1.0 || stripRect.size.height < 1.0) return nil;
    UIView *source = cellView;
    CGRect rect = stripRect;
    UIWindow *window = cellView.window;
    if (window) {
        source = window;
        rect = [cellView convertRect:stripRect toView:window];   // → window coords
    }
    if (rect.size.width < 1.0 || rect.size.height < 1.0) return nil;

    BOOL wasHidden = hideDuringSnapshot.hidden;
    hideDuringSnapshot.hidden = YES;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextTranslateCTM(ctx.CGContext, -rect.origin.x, -rect.origin.y);
        [source drawViewHierarchyInRect:source.bounds afterScreenUpdates:NO];
    }];
    hideDuringSnapshot.hidden = wasHidden;
    return out;
}

// Selection pill tint: the theme accent (custom or stock Apollo theme — Mint →
// mint, etc.), else the cell's tint, else system blue. Resolved against the
// cell's traits now: the pill's ring paints via layer borderColor (.CGColor),
// which would otherwise resolve against the ambient traits, not the cell's.
static UIColor *SRTAccentTint(UIView *cellView) {
    UIColor *accent = ApolloThemeAccentColor() ?: cellView.tintColor ?: [UIColor systemBlueColor];
    return [accent resolvedColorWithTraitCollection:cellView.traitCollection];
}

// Pans we force-disabled while the loupe is up (edge-swipe back, parallax
// transition pans). Restored in SRTDismissLoupe.
static const void *kSRTLoupeDisabledPansKey = &kSRTLoupeDisabledPansKey;

// Sliding along the row near the screen edge must NOT trigger the interactive
// swipe-back (or any transition pan) — the finger belongs to the loupe. Disable
// them for the duration of the hold and remember what we touched.
static void SRTDisableCompetingPans(UIGestureRecognizer *gr, UIView *cellView) {
    NSMutableArray<UIGestureRecognizer *> *disabled = [NSMutableArray array];
    UIGestureRecognizer *pop = SRTVisibleVCForView(cellView).navigationController.interactivePopGestureRecognizer;
    if (pop && pop.isEnabled) { pop.enabled = NO; [disabled addObject:pop]; }
    for (UIView *v = cellView; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == gr || g == scrollPan || objc_getAssociatedObject(g, kSRTGestureTypeKey)) continue;
            NSString *cls = NSStringFromClass([g class]);
            BOOL panLike = [g isKindOfClass:[UIPanGestureRecognizer class]]
                || [cls containsString:@"ParallaxTransition"];
            if (panLike && g.isEnabled) { g.enabled = NO; [disabled addObject:g]; }
        }
    }
    objc_setAssociatedObject(gr, kSRTLoupeDisabledPansKey, disabled, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SRTDismissLoupe(UIGestureRecognizer *gr, BOOL animated) {
    ApolloSRTLoupeView *loupe = objc_getAssociatedObject(gr, kSRTLoupeViewKey);
    if (loupe) {
        if (animated) {
            [UIView animateWithDuration:0.12 animations:^{
                loupe.alpha = 0.0;
                loupe.transform = CGAffineTransformMakeScale(0.9, 0.9);
            } completion:^(BOOL f) { [loupe removeFromSuperview]; }];
        } else {
            [loupe removeFromSuperview];
        }
    }
    UIScrollView *locked = objc_getAssociatedObject(gr, kSRTLoupeScrollLockKey);
    if (locked) locked.scrollEnabled = YES;   // restore the feed scroll we disabled on begin
    for (UIGestureRecognizer *g in objc_getAssociatedObject(gr, kSRTLoupeDisabledPansKey)) {
        g.enabled = YES;                      // restore swipe-back / transition pans
    }
    objc_setAssociatedObject(gr, kSRTLoupeViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeTargetsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeSelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeStripOriginKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeScrollLockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeDisabledPansKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeCancelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(gr, kSRTLoupeTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@implementation ApolloSRTGestureDelegate

// A touch the loupe claims (SRTPointClaimedForLoupe) belongs to the magnifier.
// Enforced with UIKit's own priority primitive: every competing press/pan on
// the ancestor chain is wired (once, permanently) to REQUIRE THE LOUPE TO FAIL
// before it may begin. On unclaimed touches the loupe never tracks, counts as
// failed, and everything behaves stock; on claimed ones it begins at 0.3s
// (unless the swipe veto fails it, releasing everyone) and the context menu /
// swipe-back / swipe actions simply cannot start. Deterministic — no
// enable/disable churn, no delivery-order races. (A hard disable is NOT usable
// here: a disabled recognizer wedges UIKit's arbitration and the loupe itself
// never leaves Possible; a momentary off/on flick is racy against delivery
// order. Both were tried.) Two families are wired:
//   * press-like (context menu / preview drivers);
//   * pan-like (interactive pop, Apollo's full-width swipe-back pans on the nav
//     container, edge/parallax pans, swipe actions).
// The enclosing scroll views' own pans are spared so scrolling from the corner
// keeps its native feel (a real drag moves >allowableMovement fast, failing the
// loupe naturally; once the loupe begins, the scroll-lock takes over anyway).
static const void *kSRTWiredRequirementsKey = &kSRTWiredRequirementsKey;

static void SRTWireCornerFailureRequirements(UIGestureRecognizer *loupe, UIView *cellView) {
    NSHashTable *wired = objc_getAssociatedObject(loupe, kSRTWiredRequirementsKey);
    if (!wired) {
        wired = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(loupe, kSRTWiredRequirementsKey, wired, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIGestureRecognizer *pop = SRTVisibleVCForView(cellView).navigationController.interactivePopGestureRecognizer;
    if (pop && ![wired containsObject:pop]) {
        [pop requireGestureRecognizerToFail:loupe];
        [wired addObject:pop];
    }
    for (UIView *v = cellView; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (objc_getAssociatedObject(g, kSRTGestureTypeKey)) continue;   // ours
            if (g == scrollPan || g == pop || [wired containsObject:g]) continue;
            NSString *cls = NSStringFromClass([g class]);
            BOOL pressLike = [g isKindOfClass:[UILongPressGestureRecognizer class]]
                || [cls containsString:@"Press"]
                || [cls containsString:@"ContextMenu"]
                || [cls containsString:@"Preview"];
            BOOL panLike = [g isKindOfClass:[UIPanGestureRecognizer class]];
            if (!pressLike && !panLike) continue;
            [g requireGestureRecognizerToFail:loupe];
            [wired addObject:g];
        }
    }
}


- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    id cell = objc_getAssociatedObject(gr, kSRTCommentGestureCellKey);
    NSNumber *type = objc_getAssociatedObject(gr, kSRTGestureTypeKey);
    if (!cell) return NO;
    if (type.integerValue == kSRTGestureTypeLoupe) {
        if (!sIconRowMagnifier) return NO;
        // Take the touch only where the loupe owns it (in the row band, not on
        // a subreddit/author/••• neighbour); anywhere else everything — context
        // menu included — behaves stock.
        UIView *cellView = nil;
        @try { cellView = [(ApolloSRTNode *)cell view]; } @catch (__unused id e) {}
        if (!cellView) return NO;
        NSArray<ApolloSRTTarget *> *targets = SRTTargetsForCell(cell, cellView);
        if (targets.count == 0) return NO;
        CGPoint pt = [touch locationInView:cellView];
        BOOL inside = SRTPointClaimedForLoupe(cell, cellView, targets, pt);
        if (inside) {
            // Touch-down point (window coords) — shouldBegin measures travel
            // against it to tell a hold from a swipe.
            objc_setAssociatedObject(gr, kSRTLoupeTouchStartKey,
                                     [NSValue valueWithCGPoint:[touch locationInView:nil]],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SRTWireCornerFailureRequirements(gr, cellView);
        }
        return inside;
    }
    // The comment tap only cares about the comment-bubble region.
    if (!sInfoRowTapComments) return NO;   // Info Row switch OFF: stock tap (opens post at top)
    UIView *cellView = nil;
    @try { cellView = [(ApolloSRTNode *)cell view]; } @catch (__unused id e) {}
    ApolloSRTNode *commentsNode = SRTCommentsNodeForCell(cell);
    return SRTTouchHitsNode(commentsNode, cellView, touch, kSRTCommentInsets);
}

// Max finger travel between touch-down and the 0.3s mark that still reads as a
// hold. Vertical is strict (a slow swipe must not pop the loupe); horizontal
// gets more room (sliding along the row is the loupe's own axis).
static const CGFloat kSRTHoldMaxTravelY = 16.0;
static const CGFloat kSRTHoldMaxTravel  = 40.0;

// Touch delivery already gated to the strip in shouldReceiveTouch; at transition
// time re-check the flag/cell wiring and veto swipe-intent touches. Returning NO
// fails the press cleanly, releasing every recognizer wired to wait on us.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    NSNumber *type = objc_getAssociatedObject(gr, kSRTGestureTypeKey);
    if (type.integerValue != kSRTGestureTypeLoupe) return YES;
    id cell = objc_getAssociatedObject(gr, kSRTCommentGestureCellKey);
    if (!sIconRowMagnifier || !cell) return NO;

    // The feed is already scrolling under this touch — that's a swipe, not a hold.
    UIView *cellView = nil;
    @try { cellView = [(ApolloSRTNode *)cell view]; } @catch (__unused id e) {}
    for (UIView *v = cellView; v; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]]) {
            if (((UIScrollView *)v).isDragging) {
                ApolloLog(@"[StatsRow] loupe vetoed — feed is scrolling");
                return NO;
            }
            break;
        }
    }
    // The finger has visibly travelled since touch-down — swipe intent.
    NSValue *startVal = objc_getAssociatedObject(gr, kSRTLoupeTouchStartKey);
    if (startVal) {
        CGPoint start = startVal.CGPointValue;
        CGPoint now = [gr locationInView:nil];
        CGFloat dx = now.x - start.x, dy = now.y - start.y;
        if (fabs(dy) > kSRTHoldMaxTravelY || hypot(dx, dy) > kSRTHoldMaxTravel) {
            ApolloLog(@"[StatsRow] loupe vetoed — finger travelled (%.0f, %.0f)", dx, dy);
            return NO;
        }
    }
    return YES;
}

// Always allow simultaneous recognition. Exclusivity CANNOT be used here: if any
// other recognizer happens to be active on the touch (hover, focus observers,
// scroll internals — racy across devices), an exclusive loupe silently never
// leaves Possible ("hold does nothing"). The hijack risks are each handled
// directly instead: cancelsTouchesInView kills row selection, the scroll-lock
// kills scrolling, and SRTDisableCompetingPans kills the edge-swipe back /
// transition pans while the loupe is up.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// Never wait on anyone: refuse failure requirements in OUR direction. (The system
// press being made to wait on US is fine and handled by the neutralizer above.)
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
        shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

// Belt-and-braces: anything press-like we did not neutralize still has to wait
// for the loupe to fail (which it does instantly outside the strip).
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (!sIconRowMagnifier) return NO;   // feature off -> never touch the context menu
    NSNumber *type = objc_getAssociatedObject(gr, kSRTGestureTypeKey);
    if (type.integerValue != kSRTGestureTypeLoupe) return NO;
    if (objc_getAssociatedObject(other, kSRTGestureTypeKey)) return NO;   // our own gestures
    NSString *cls = NSStringFromClass([other class]);
    BOOL yes = [cls containsString:@"ContextMenu"] || [cls containsString:@"Preview"]
        || [cls containsString:@"Menu"] || [cls containsString:@"Press"]
        || [other isKindOfClass:[UILongPressGestureRecognizer class]];
    return yes;
}

// The tap itself: arm the jump. The native row selection (not cancelled) opens the
// post; the pushed CommentsViewController consumes the flag on appear.
- (void)srtCommentTapFired:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    SRTArmJumpPending();
    // Match the vote buttons' native feedback: a light tick acknowledging the tap.
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    ApolloLog(@"[StatsRow] comment bubble tapped — arming jump-to-comments");
}

// How far past the interactive band (claim ∪ strip) the finger may wander before
// the hold flips into "release to cancel". Generous enough that normal sliding
// (which drifts vertically) never trips it; small enough that a deliberate
// drag-away reads instantly. Fully reversible until the finger lifts.
static const CGFloat kSRTCancelSlopX = 48.0;
static const CGFloat kSRTCancelSlopY = 64.0;

// Refresh the loupe's selection + position from the current finger location.
- (void)srtSyncLoupeForGesture:(UIGestureRecognizer *)gr cell:(id)cell cellView:(UIView *)cellView {
    ApolloSRTLoupeView *loupe = objc_getAssociatedObject(gr, kSRTLoupeViewKey);
    NSArray<ApolloSRTTarget *> *targets = objc_getAssociatedObject(gr, kSRTLoupeTargetsKey);
    UIView *host = cellView.window;
    if (!loupe || targets.count == 0 || !host) return;
    CGPoint pCell = [gr locationInView:cellView];

    // Drag-away-to-cancel: outside the escape band the loupe dims into a
    // "Release to Cancel" state and releasing activates nothing; sliding back
    // re-engages. The band is the whole interactive area a hold can start in
    // (claim ∪ strip) plus slop, so the loupe can never SPAWN cancelled.
    CGRect band = CGRectUnion(SRTStripRect(targets), SRTClaimRect(cell, cellView, targets));
    BOOL cancelled = !CGRectContainsPoint(CGRectInset(band, -kSRTCancelSlopX, -kSRTCancelSlopY), pCell);
    BOOL wasCancelled = [objc_getAssociatedObject(gr, kSRTLoupeCancelKey) boolValue];
    if (cancelled != wasCancelled) {
        objc_setAssociatedObject(gr, kSRTLoupeCancelKey, @(cancelled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [loupe setCancelledAppearance:cancelled];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        ApolloLog(@"[StatsRow] loupe %@", cancelled ? @"dragged away — release to cancel" : @"re-engaged");
    }
    if (cancelled) {   // keep tracking the finger (dimmed) but hold the last selection
        [loupe positionAboveScreenPoint:[gr locationInView:host] inHost:host];
        return;
    }

    NSInteger sel = SRTNearestTargetIndex(targets, pCell.x);
    NSNumber *prev = objc_getAssociatedObject(gr, kSRTLoupeSelKey);
    objc_setAssociatedObject(gr, kSRTLoupeSelKey, @(sel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSRTTarget *t = targets[sel];
    CGPoint stripOrigin = [(NSValue *)objc_getAssociatedObject(gr, kSRTLoupeStripOriginKey) CGPointValue];
    CGRect rectInStrip = CGRectOffset(t.rect, -stripOrigin.x, -stripOrigin.y);
    UIColor *tint = objc_getAssociatedObject(gr, kSRTLoupeTintKey) ?: SRTAccentTint(cellView);
    [loupe selectRect:rectInStrip caption:t.caption tint:tint];
    [loupe positionAboveScreenPoint:[gr locationInView:host] inHost:host];
    if (prev && prev.integerValue != sel) {
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    }
}

- (void)srtLoupeLongPress:(UILongPressGestureRecognizer *)gr {
    id cell = objc_getAssociatedObject(gr, kSRTCommentGestureCellKey);
    if (!cell) return;
    UIView *cellView = nil;
    @try { cellView = [(ApolloSRTNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return;

    switch (gr.state) {
        case UIGestureRecognizerStateBegan: {
            if (!sIconRowMagnifier) return;
            NSArray<ApolloSRTTarget *> *targets = SRTTargetsForCell(cell, cellView);
            UIView *host = cellView.window;
            if (targets.count == 0 || !host) return;
            CGRect stripRect = SRTStripRect(targets);
            UIImage *img = SRTSnapshotStrip(cellView, stripRect, nil);   // loupe not shown yet
            if (!img) return;
            CGFloat zoom = (host.bounds.size.width - 40.0) / MAX(stripRect.size.width, 1.0);
            zoom = MAX(1.4, MIN(zoom, 2.4));
            ApolloSRTLoupeView *loupe = [[ApolloSRTLoupeView alloc] initWithImage:img stripSize:stripRect.size zoom:zoom];
            loupe.alpha = 0.0;
            loupe.transform = CGAffineTransformMakeScale(0.85, 0.85);
            [host addSubview:loupe];
            // The stat button under the finger is still in its pressed (dimmed)
            // state in this first snapshot — our cancelsTouchesInView cancellation
            // un-highlights it only after this action returns, and the layer-backed
            // node redraws a frame later. Re-snapshot shortly after and swap the
            // strip image so every icon shows at full brightness.
            {
                __weak ApolloSRTLoupeView *weakLoupe = loupe;
                CGRect snapRect = stripRect;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ApolloSRTLoupeView *l = weakLoupe;
                    if (!l || !l.superview) return;
                    UIImage *fresh = SRTSnapshotStrip(cellView, snapRect, l);   // hide the loupe so it isn't captured
                    if (fresh) l.stripImageView.image = fresh;
                });
            }
            objc_setAssociatedObject(gr, kSRTLoupeViewKey, loupe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(gr, kSRTLoupeTargetsKey, targets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(gr, kSRTLoupeStripOriginKey, [NSValue valueWithCGPoint:stripRect.origin], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(gr, kSRTLoupeCancelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // fresh hold, fresh escape state
            objc_setAssociatedObject(gr, kSRTLoupeTintKey, SRTAccentTint(cellView), OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // resolve once per hold, not per touch-move
            // Lock the feed's scroll while the loupe is up so sliding to pick an icon
            // never scrolls the list; restored in SRTDismissLoupe.
            for (UIView *v = cellView; v; v = v.superview) {
                if ([v isKindOfClass:[UIScrollView class]]) {
                    UIScrollView *sv = (UIScrollView *)v;
                    if (sv.isScrollEnabled) {
                        sv.scrollEnabled = NO;
                        objc_setAssociatedObject(gr, kSRTLoupeScrollLockKey, sv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    break;
                }
            }
            // And the horizontal escape hatches (edge-swipe back / transition pans):
            // sliding across the row near the screen edge must move the pill, not
            // pop the page. Restored in SRTDismissLoupe.
            SRTDisableCompetingPans(gr, cellView);
            [self srtSyncLoupeForGesture:gr cell:cell cellView:cellView];
            [UIView animateWithDuration:0.14 animations:^{
                loupe.alpha = 1.0;
                loupe.transform = CGAffineTransformIdentity;
            }];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            break;
        }
        case UIGestureRecognizerStateChanged:
            [self srtSyncLoupeForGesture:gr cell:cell cellView:cellView];
            break;
        case UIGestureRecognizerStateEnded: {
            NSArray<ApolloSRTTarget *> *targets = objc_getAssociatedObject(gr, kSRTLoupeTargetsKey);
            NSInteger sel = [objc_getAssociatedObject(gr, kSRTLoupeSelKey) integerValue];
            BOOL cancelled = [objc_getAssociatedObject(gr, kSRTLoupeCancelKey) boolValue];
            ApolloSRTTarget *t = (!cancelled && sel >= 0 && sel < (NSInteger)targets.count) ? targets[sel] : nil;
            SRTDismissLoupe(gr, YES);
            if (t) {
                ApolloLog(@"[StatsRow] loupe released on %@", t.caption);
                SRTActivateTarget(cell, cellView, t);
            } else if (cancelled) {
                ApolloLog(@"[StatsRow] loupe released in cancel zone — dismissed, no action");
            }
            break;
        }
        default:
            SRTDismissLoupe(gr, YES);
            break;
    }
}

@end

static ApolloSRTGestureDelegate *SRTDelegate(void) {
    static ApolloSRTGestureDelegate *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [ApolloSRTGestureDelegate new]; });
    return d;
}

static void SRTInstallInfoRowGestures(id cell) {
    if (!cell) return;
    if (objc_getAssociatedObject(cell, kSRTCommentGestureInstalledKey)) return;
    UIView *cellView = nil;
    @try { cellView = [(ApolloSRTNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return;

    // 1) Non-consuming tap on the comment bubble -> arm jump-to-comments.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:SRTDelegate()
                                                                          action:@selector(srtCommentTapFired:)];
    tap.cancelsTouchesInView = NO;      // let native selection open the post
    tap.delaysTouchesBegan = NO;        // don't interfere with scrolling
    tap.delaysTouchesEnded = NO;        // don't delay the row selection
    tap.delegate = SRTDelegate();
    // Unsafe-unretained back-ref: the gesture lives inside the cell's view, so it
    // never outlives the cell — no retain cycle, always valid while the gr exists.
    objc_setAssociatedObject(tap, kSRTCommentGestureCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(tap, kSRTGestureTypeKey, @(kSRTGestureTypeCommentTap), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cellView addGestureRecognizer:tap];

    // 2) Press-and-hold loupe over the whole info-row strip.
    UILongPressGestureRecognizer *loupe = [[UILongPressGestureRecognizer alloc] initWithTarget:SRTDelegate()
                                                                                        action:@selector(srtLoupeLongPress:)];
    loupe.minimumPressDuration = 0.3;
    // The default 10pt is strict enough that a wobbly thumb silently fails the
    // press. Keep it loose; swipe intent is vetoed at begin time instead
    // (gestureRecognizerShouldBegin:).
    loupe.allowableMovement = 60.0;
    loupe.cancelsTouchesInView = YES;   // own the touch while the loupe is up
    loupe.delegate = SRTDelegate();
    objc_setAssociatedObject(loupe, kSRTCommentGestureCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(loupe, kSRTGestureTypeKey, @(kSRTGestureTypeLoupe), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cellView addGestureRecognizer:loupe];

    objc_setAssociatedObject(cell, kSRTCommentGestureInstalledKey, @[tap, loupe], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - CommentsViewController: scroll to the first comment when jump is pending
//
// Mirrors ApolloInboxCommentScroll's settle-then-pin approach but targets the
// first CommentCellNode and is gated on our jump-pending flag (a *normal*
// full-comments view, never an isolated thread). The two never fight: ICS only
// acts on isolated threads, we only act when a jump is pending.

static const NSTimeInterval kSRTInterval = 0.10;
static const NSTimeInterval kSRTDeadline = 6.0;    // let the comment tree load over the network
static const CGFloat kSRTDrift = 4.0;
static const int kSRTHeldToFinish = 4;

static const void *kSRTGenKey    = &kSRTGenKey;    // NSNumber long
static const void *kSRTUserKey   = &kSRTUserKey;   // NSNumber bool: user dragged -> stop
static const void *kSRTDoneKey   = &kSRTDoneKey;   // NSNumber bool
static const void *kSRTHeldKey   = &kSRTHeldKey;   // NSNumber int: consecutive on-target ticks

static long gSRTGen = 0;

static NSNumber *SRTNum(id vc, const void *key) { return objc_getAssociatedObject(vc, key); }
static void SRTSet(id vc, const void *key, id val) {
    objc_setAssociatedObject(vc, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UITableView *SRTFindTable(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *s in v.subviews) {
        UITableView *t = SRTFindTable(s);
        if (t) return t;
    }
    return nil;
}

static UITableView *SRTTableForVC(UIViewController *vc) {
    id tableNode = SRTIvar(vc, "tableNode");
    if (tableNode) {
        SEL viewSel = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSel]) {
            UIView *tv = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSel);
            if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
        }
    }
    return SRTFindTable(vc.viewIfLoaded);
}

// First row whose node is a CommentCellNode (the start of the comment section,
// after the post header / media / summary / action rows).
static NSIndexPath *SRTFirstCommentIndexPath(id tableNode, UITableView *tableView) {
    Class commentCellClass = NSClassFromString(@"_TtC6Apollo15CommentCellNode");
    if (!commentCellClass) return nil;
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return nil;
    NSInteger sections = [tableView numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tableView numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (node && [node isKindOfClass:commentCellClass]) return ip;
        }
    }
    return nil;
}

// Land the action bar flush at the top of the scroll area (just under the nav
// bar). The action bar is the *last* row of the post header, so putting its top
// at the content-inset boundary means no post-body text peeks above it — the
// discussion (summary + first comments) sits right below, which is where a
// "jump to comments" tap wants to be. A previous 8pt margin left a sliver of the
// body's final line (its descenders) hanging above the bar, which read as a
// glitch rather than a deliberate frame (issue #622). 0 removes it cleanly.
static const CGFloat kSRTLandingMargin = 0.0;

// Content-space Y of the post's quick action bar (up/down/save/reply/share). It's a
// subnode (quickBarNode) at the bottom of the CommentsHeaderCellNode, not its own row.
// Returns NAN if not resolvable. A UITableView's layer bounds.origin == contentOffset,
// so converting a descendant layer into it yields content coordinates directly.
static CGFloat SRTQuickBarTopContentY(id tableNode, UITableView *tableView) {
    Class headerClass = NSClassFromString(@"_TtC6Apollo22CommentsHeaderCellNode");
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!headerClass || !tableNode || ![tableNode respondsToSelector:nodeSel] || !tableView.layer) return NAN;
    NSInteger sections = [tableView numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tableView numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (!node || ![node isKindOfClass:headerClass]) continue;
            id quickBar = SRTIvar(node, "quickBarNode");
            CALayer *qbLayer = nil;
            @try { qbLayer = [(ApolloSRTNode *)quickBar layer]; } @catch (__unused id e) {}
            if (!qbLayer) return NAN;
            CGRect rq = [qbLayer convertRect:qbLayer.bounds toLayer:tableView.layer];
            if (CGRectIsNull(rq) || CGRectIsEmpty(rq) || CGRectIsInfinite(rq)) return NAN;
            return rq.origin.y;
        }
    }
    return NAN;
}

// The content-offset that seats the landing anchor — the post's action bar
// (preferred, so the up/down/reply row stays visible), else the first comment as a
// fallback — at the top of the scroll area, just under the nav bar. Clamped to the
// current scroll range. Returns NAN when there's nothing to anchor to yet.
static CGFloat SRTLandingOffset(id tableNode, UITableView *tv, NSIndexPath *firstCommentIP) {
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    CGFloat maxOff = MAX(-insetTop, tv.contentSize.height - viewportH + insetBottom);
    CGFloat targetTop;
    CGFloat qbTop = SRTQuickBarTopContentY(tableNode, tv);
    if (!isnan(qbTop))          targetTop = qbTop - kSRTLandingMargin;
    else if (firstCommentIP)    targetTop = [tv rectForRowAtIndexPath:firstCommentIP].origin.y;
    else                        return NAN;
    return MIN(MAX(targetTop - insetTop, -insetTop), maxOff);
}

// -1 not ready, 0 corrected (was off), 1 already on target.
//
// The landing anchor is the post's action bar, which lives at the bottom of the
// header cell. Apollo builds that header synchronously from the RDKLink the instant
// the CommentsViewController loads — long before the comment tree streams in over
// the network — so its content-Y is resolvable during the push transition itself.
// That's what lets us land *invisibly* (issue #622): we don't wait for a comment to
// exist, we pin to the header the moment it's measured, so the view slides in
// already scrolled to the discussion instead of opening at the top and jumping down.
static int SRTPinLanding(UIViewController *vc) {
    id tableNode = SRTIvar(vc, "tableNode");
    UITableView *tv = SRTTableForVC(vc);
    if (!tv) return -1;

    // The comments view is an ASTableNode and does NOT forward
    // scrollViewWillBeginDragging: to the VC (device-proven — see
    // ApolloLiveCommentsFollow), so we can't rely on that delegate callback to learn
    // the user took over. Read the scroll state directly instead: never fight a
    // finger on the list. A real drag/fling hands the jump over for good; a plain
    // touch-down (tracking, e.g. tapping to collapse a comment) just skips this
    // frame's pin so we don't tug against the touch.
    if (tv.isDragging || tv.isDecelerating) {
        SRTSet(vc, kSRTUserKey, @YES);
        SRTSet(vc, kSRTDoneKey, @YES);
        return -1;
    }
    if (tv.isTracking) return -1;

    CGFloat h = tv.contentSize.height;
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    if (viewportH < 1.0) return -1;                                  // not laid out yet
    if ((h + insetTop + insetBottom) <= viewportH + 1.0) return -1;  // whole thread fits — nothing to do

    CGFloat qbTop = SRTQuickBarTopContentY(tableNode, tv);
    // Only pay for the first-comment scan when the header anchor is unavailable.
    NSIndexPath *first = isnan(qbTop) ? SRTFirstCommentIndexPath(tableNode, tv) : nil;
    CGFloat desired = SRTLandingOffset(tableNode, tv, first);
    if (isnan(desired)) return -1;                                   // nothing to anchor to yet

    CGFloat cur = tv.contentOffset.y;
    if (fabs(cur - desired) > kSRTDrift) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, desired) animated:NO];
        ApolloLog(@"[StatsRow] pin: qbTop=%.1f cur=%.1f -> %.1f (h=%.1f vh=%.1f inTop=%.1f)",
                  qbTop, cur, desired, h, viewportH, insetTop);
        return 0;
    }
    return 1;
}

// YES when the action-bar landing is fully reachable right now — enough content
// below it to scroll its top to the nav bar. A cold long-body post whose comments
// haven't loaded yet is NOT reachable (the target clamps short); we keep ticking so
// the landing finalizes once the tree grows, rather than finishing at a clamped
// interim position.
static BOOL SRTLandingReachable(id tableNode, UITableView *tv) {
    CGFloat qbTop = SRTQuickBarTopContentY(tableNode, tv);
    if (isnan(qbTop)) return NO;
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    CGFloat maxOff = MAX(-insetTop, tv.contentSize.height - viewportH + insetBottom);
    CGFloat target = (qbTop - kSRTLandingMargin) - insetTop;
    return target <= maxOff + 0.5;
}

static void SRTScheduleTick(__weak UIViewController *weakVC, long gen, NSDate *deadline);

static void SRTTick(__weak UIViewController *weakVC, long gen, NSDate *deadline) {
    UIViewController *vc = weakVC;
    if (!vc) return;
    NSNumber *curGen = SRTNum(vc, kSRTGenKey);
    if (!curGen || curGen.longValue != gen) return;   // superseded
    if ([SRTNum(vc, kSRTUserKey) boolValue]) return;   // user took over
    if ([SRTNum(vc, kSRTDoneKey) boolValue]) return;

    BOOL pastDeadline = ([deadline timeIntervalSinceNow] <= 0);

    id tableNode = SRTIvar(vc, "tableNode");
    UITableView *tableView = SRTTableForVC(vc);
    if (!tableView) {
        if (!pastDeadline) SRTScheduleTick(weakVC, gen, deadline);
        return;
    }

    // Pin to the header's action bar as soon as it's measured — no waiting on the
    // comment tree. This backstops the viewDidLayoutSubviews pin for layout passes
    // that don't re-fire, and finalizes the cold long-body case: a post whose action
    // bar couldn't reach the top pre-load becomes reachable once its comments arrive.
    int r = SRTPinLanding(vc);                                 // -1 not ready, 0 corrected, 1 on target
    // "Done" only once we're on target AND the anchor is fully reachable (comments
    // provided the height) — otherwise a cold long-body post would finish while its
    // comments are still loading, settling at a clamped interim position.
    BOOL settled = (r == 1) && SRTLandingReachable(tableNode, tableView);

    if (settled) {
        int held = [SRTNum(vc, kSRTHeldKey) intValue] + 1;
        SRTSet(vc, kSRTHeldKey, @(held));
        if (held >= kSRTHeldToFinish) {
            SRTSet(vc, kSRTDoneKey, @YES);
            ApolloLog(@"[StatsRow] landed (action bar at top) — done (gen=%ld)", gen);
            return;
        }
    } else {
        SRTSet(vc, kSRTHeldKey, @(0));      // still settling — reset the streak
    }

    if (pastDeadline) {
        SRTPinLanding(vc);                 // one last best-effort placement
        SRTSet(vc, kSRTDoneKey, @YES);     // stop auto-pinning past the network load window
        ApolloLog(@"[StatsRow] jump deadline reached — settling (gen=%ld)", gen);
        return;
    }
    SRTScheduleTick(weakVC, gen, deadline);
}

static void SRTScheduleTick(__weak UIViewController *weakVC, long gen, NSDate *deadline) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSRTInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SRTTick(weakVC, gen, deadline);
    });
}

// MARK: - Context-menu suppression in the icon corner (deterministic)
//
// Fighting the context menu's press recognizer via gesture arbitration proved
// racy (see the loupe gesture notes). This is the airtight approach: Apollo's
// long-press menu is a real UIContextMenuInteraction whose delegate
// (PostCellActionTaker for feed posts, CommentsHeaderSectionController for the
// comments header) is asked for a configuration WHEN the press is recognized.
// Return nil there and no menu appears — no timing, no arbitration. We return
// nil only where the loupe would claim the press (SRTPointClaimedForLoupe) and
// the magnifier is on; everywhere else %orig runs and the menu behaves stock.
static BOOL SRTShouldSuppressMenu(id interaction, CGPoint location) {
    if (!sIconRowMagnifier) return NO;
    UIView *iview = nil;
    @try { if ([interaction respondsToSelector:@selector(view)]) iview = [interaction view]; } @catch (__unused id e) {}
    if (![iview isKindOfClass:[UIView class]]) return NO;
    // Recover the cell + its cellView by finding our loupe gesture on the
    // interaction's view (or an ancestor). That gesture carries the cell node.
    id cell = nil; UIView *cellView = nil;
    for (UIView *v = iview; v && !cell; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if ([objc_getAssociatedObject(g, kSRTGestureTypeKey) integerValue] == kSRTGestureTypeLoupe) {
                cell = objc_getAssociatedObject(g, kSRTCommentGestureCellKey);
                cellView = v;
                break;
            }
        }
    }
    if (!cell || !cellView) return NO;
    NSArray<ApolloSRTTarget *> *targets = SRTTargetsForCell(cell, cellView);
    if (targets.count == 0) return NO;
    CGPoint p = (iview == cellView) ? location : [iview convertPoint:location toView:cellView];
    return SRTPointClaimedForLoupe(cell, cellView, targets, p);
}

%hook _TtC6Apollo19PostCellActionTaker
- (id)contextMenuInteraction:(id)interaction configurationForMenuAtLocation:(CGPoint)location {
    if (SRTShouldSuppressMenu(interaction, location)) {
        ApolloLog(@"[StatsRow] suppressed post context menu (icon corner)");
        return nil;
    }
    return %orig;
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (id)contextMenuInteraction:(id)interaction configurationForMenuAtLocation:(CGPoint)location {
    if (SRTShouldSuppressMenu(interaction, location)) {
        ApolloLog(@"[StatsRow] suppressed header context menu (icon corner)");
        return nil;
    }
    return %orig;
}
%end

// MARK: - Hooks: cells with an info row install the tap + loupe gestures

%hook _TtC6Apollo17LargePostCellNode
- (void)didLoad {
    %orig;
    SRTInstallInfoRowGestures(self);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didLoad {
    %orig;
    SRTInstallInfoRowGestures(self);
}
%end

// The post header inside comments (score · % upvoted · age · 🌐) gets the loupe
// too; its comment bubble is absent so the jump tap simply never claims a touch.
%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didLoad {
    %orig;
    SRTInstallInfoRowGestures(self);
}
%end

// MARK: - Hook: CommentsViewController consumes the pending jump

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!SRTConsumeJumpPending()) return;   // only when a bubble tap armed us

    long gen = ++gSRTGen;
    SRTSet(self, kSRTGenKey, @(gen));
    SRTSet(self, kSRTUserKey, @NO);
    SRTSet(self, kSRTDoneKey, @NO);
    SRTSet(self, kSRTHeldKey, @(0));

    // Land BEFORE the push transition paints. The post header (and its action bar)
    // is usually already measured by now — built synchronously from the link —
    // so this first pin makes the view slide in already scrolled to the
    // discussion, instead of opening at the top and then jumping down (#622).
    // viewDidLayoutSubviews + the tick loop cover the passes where the header
    // wasn't measured at this exact instant.
    SRTPinLanding((UIViewController *)self);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kSRTDeadline];
    SRTScheduleTick((UIViewController *)self, gen, deadline);
    ApolloLog(@"[StatsRow] comments will appear with jump pending — landing early (gen=%ld)", gen);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Belt-and-braces: if the header measured too late to pin before the transition
    // painted (rare), catch up now so we still land on the action bar.
    if ([SRTNum(self, kSRTGenKey) longValue] == 0) return;   // no jump active for this VC
    if ([SRTNum(self, kSRTDoneKey) boolValue]) return;
    if ([SRTNum(self, kSRTUserKey) boolValue]) return;
    SRTPinLanding((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (![NSThread isMainThread]) return;
    if ([SRTNum(self, kSRTGenKey) longValue] == 0) return;   // no jump active for this VC
    if ([SRTNum(self, kSRTDoneKey) boolValue]) return;
    if ([SRTNum(self, kSRTUserKey) boolValue]) return;
    // Flash-free pin: this runs in the same layout pass in which Apollo re-parks
    // the offset, so its top-of-post value never paints. Anchored on the header,
    // it fires from the very first pass during the push (the proven sibling
    // technique in ApolloInboxCommentScroll).
    SRTPinLanding((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SRTSet(self, kSRTGenKey, @(++gSRTGen));   // supersede any in-flight loop
    SRTSet(self, kSRTUserKey, @YES);
    SRTSet(self, kSRTDoneKey, @YES);
}

- (void)scrollViewWillBeginDragging:(id)scrollView {
    %orig;
    if ([SRTNum(self, kSRTGenKey) longValue] != 0) {   // a jump loop is/was active for us
        SRTSet(self, kSRTUserKey, @YES);               // a manual drag cancels the jump for good
        SRTSet(self, kSRTDoneKey, @YES);
    }
}

%end
