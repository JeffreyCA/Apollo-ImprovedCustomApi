// ApolloCreatedAtAlert
//
// Tap one of the info-row detail icons — % upvoted (smiley), timestamp (age), or
// edited (pencil) — to reveal its detail (a ratio or an absolute date). The Info
// Row "Popup" / "Overlay" modes pick the presentation (a dismissable alert or a
// small auto-fading card); with both off Apollo's stock touch handling is unchanged.
//
// Wiring — two paths, because Apollo wires these icons two different ways:
//   • age + % upvoted: Apollo leaves these ApolloButtonNodes non-interactive
//     (userInteractionEnabled == NO, no target-action), so one UITapGestureRecognizer
//     per cell (installed on the always-view-backed cell view) hit-tests their CALayers
//     from shouldReceiveTouch:, picks the nearest, and cancelsTouchesInView swallows the
//     touch while we present the detail.
//   • edited pencil: this one IS a natively interactive ApolloButtonNode with a
//     target-action (-editedButtonTappedWithSender:), and its control fires on touch-up
//     faster than our tap gesture can reliably win — so the cell gesture deliberately
//     does NOT claim edited (see ApolloInfoTapShouldReceiveTouch). Instead we %hook
//     editedButtonTappedWithSender: directly and suppress %orig, which is race-free.
// Both paths funnel into ApolloPresentInfoDetail (the magnifier loupe uses it too).
//
// Hooked cells: CommentCellNode (ageNode, editedIndicatorNode), CommentsHeader /
// LargePost / CompactPost cell nodes (postInfoNode.{age,percentageLiked,edited}ButtonNode).
// The edited take-over hook lives on CommentCellNode + CommentsHeaderCellNode (the only
// cells whose edited pencil is natively tappable — it doesn't appear in feed post cells).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloCreatedAtAlert.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
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

// Shorter "Jul 8, 2026 at 12:26 PM" form for the compact overlay card.
static NSDateFormatter *ApolloCompactDateFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterMediumStyle;
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


// Data accessors for the three info kinds (createdUTC is declared on RDKComment above).
@interface RDKLink (ApolloInfoAccessor)
@property (nonatomic, readonly) NSDate *edited;
@property (nonatomic, readonly) double upvoteRatio;
@end
@interface RDKComment (ApolloInfoEditedAccessor)
@property (nonatomic, readonly) NSDate *edited;
@end

// Build the two text lines for an info kind. line1 = the bold headline, line2 =
// the detail (may be nil). `condensed` (the overlay) trims the phrasing and uses
// a shorter date so the little card stays small; the full form (the popup) keeps
// Apollo's alert wording. Returns NO when there's no data to show.
static BOOL ApolloInfoLinesForKind(ApolloInfoKind kind, id link, id comment, BOOL condensed,
                                   NSString **outLine1, NSString **outLine2) {
    NSDateFormatter *dateFmt = condensed ? ApolloCompactDateFormatter() : ApolloAbsoluteDateFormatter();
    *outLine2 = nil;
    switch (kind) {
        case ApolloInfoKindAge: {
            BOOL isComment = (comment != nil);
            NSDate *date = isComment ? [comment createdUTC] : [link createdUTC];
            if (![date isKindOfClass:[NSDate class]]) return NO;
            NSString *verb = isComment ? @"Commented" : @"Posted";
            NSString *rel = ApolloRelativeAgoString(date) ?: @"Just now";
            *outLine1 = [rel isEqualToString:@"Just now"] ? [NSString stringWithFormat:@"%@ %@", verb, rel]
                                                          : [NSString stringWithFormat:@"%@ %@ Ago", verb, rel];
            if (fabs([date timeIntervalSinceNow]) < 5.0) return YES;
            *outLine2 = condensed ? [dateFmt stringFromDate:date]
                                  : [NSString stringWithFormat:@"%@ on %@", verb, [dateFmt stringFromDate:date]];
            return YES;
        }
        case ApolloInfoKindPercentage: {
            if (![link respondsToSelector:@selector(upvoteRatio)]) return NO;
            double ratio = [link upvoteRatio];
            if (ratio <= 0.0 || ratio > 1.0) return NO;
            long pct = lround(ratio * 100.0);
            *outLine1 = [NSString stringWithFormat:@"%ld%% Upvoted", pct];
            *outLine2 = condensed ? nil : [NSString stringWithFormat:@"%ld%% of voters upvoted this post.", pct];
            return YES;
        }
        case ApolloInfoKindEdited: {
            NSDate *date = comment ? [comment edited] : [link edited];
            if (![date isKindOfClass:[NSDate class]]) return NO;
            NSString *rel = ApolloRelativeAgoString(date) ?: @"Just now";
            *outLine1 = [rel isEqualToString:@"Just now"] ? @"Edited Just now"
                                                          : [NSString stringWithFormat:@"Edited %@ Ago", rel];
            if (fabs([date timeIntervalSinceNow]) < 5.0) return YES;
            *outLine2 = condensed ? [dateFmt stringFromDate:date]
                                  : [NSString stringWithFormat:@"Last edited on %@", [dateFmt stringFromDate:date]];
            return YES;
        }
    }
    return NO;
}

BOOL ApolloPresentInfoDetail(ApolloInfoKind kind, id link, id comment, UIView *anchorView,
                             CGRect anchorRectInWindow, UIWindow *window) {
    if (!sInfoRowPopupMode && !sInfoRowOverlayMode) return NO;   // both off: inert
    BOOL overlay = sInfoRowOverlayMode && window && !CGRectIsEmpty(anchorRectInWindow) && !CGRectIsNull(anchorRectInWindow);
    NSString *line1 = nil, *line2 = nil;
    if (!ApolloInfoLinesForKind(kind, link, comment, /*condensed=*/overlay, &line1, &line2) || line1.length == 0) return NO;

    if (overlay) {
        ApolloPresentInfoOverlay(line1, line2, anchorView, anchorRectInWindow);
        return YES;
    }
    // Popup mode (or overlay with no resolvable anchor → fall back to the popup so
    // the tap isn't lost).
    UIViewController *presenter = window ? [window visibleViewController] : nil;
    if (!presenter) return NO;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:line1 message:line2
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
    return YES;
}

// MARK: - Transient info overlay (Info Row "Overlay" mode)

// Only one overlay on screen at a time (rapid taps replace, not stack).
static const NSInteger kApolloTimeOverlayTag = 0x54494D45;  // 'TIME'
static __weak UIView *sApolloTimeOverlay = nil;

void ApolloPresentInfoOverlay(NSString *line1, NSString *line2, UIView *anchorView, CGRect anchorRectInWindow) {
    if (line1.length == 0 || !anchorView) return;

    // Parent to the cell itself so the card is "glued" to the row: it rides on top
    // of the cell's own content, scrolls with it, and clips away as the cell leaves
    // the screen — instead of hovering at a fixed spot on the window while the list
    // scrolls underneath. (Parenting to the scroll view hid it behind the cells.)
    UIView *host = anchorView;

    [sApolloTimeOverlay removeFromSuperview];
    sApolloTimeOverlay = nil;

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    para.lineSpacing = 2.0;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:line1 attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSParagraphStyleAttributeName: para,
    }];
    if (line2) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:line2] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: [[UIColor whiteColor] colorWithAlphaComponent:0.72],
            NSParagraphStyleAttributeName: para,
        }]];
    }

    UILabel *label = [[UILabel alloc] init];
    // Pin the fonts: ThemeRuntime re-fonts labels when they ATTACH to the window
    // (RethemeFontOnAttach) — i.e. after we've measured. A themed font with taller
    // metrics (SF Rounded/New York) made the two lines stop fitting the measured
    // frame, so UILabel silently dropped the date line (the "only 'Posted 1d Ago'"
    // bug on themed devices). The theme's own design keeps system chrome in SF
    // (alerts included), so pinning this floating card is consistent — and keeps
    // measurement == rendering, always two lines.
    ApolloThemeRuntimeSetFontPinned(label, YES);
    label.numberOfLines = 0;
    label.attributedText = text;
    CGFloat maxTextW = MIN(300.0, host.bounds.size.width - 32.0);
    CGSize textSize = [label sizeThatFits:CGSizeMake(maxTextW, CGFLOAT_MAX)];

    CGFloat padH = 12.0, padV = 8.0;
    CGFloat cardW = ceil(textSize.width) + padH * 2.0;
    CGFloat cardH = ceil(textSize.height) + padV * 2.0;
    CGFloat corner = MIN(14.0, cardH / 2.0);

    // Border + a faint fill both tint with the theme accent ("undercolour"); the
    // card itself is a dark material so the text stays readable over any feed image.
    UIColor *accent = ApolloThemeAccentColor() ?: host.tintColor ?: [UIColor systemBlueColor];
    accent = [accent resolvedColorWithTraitCollection:host.traitCollection];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, cardH)];
    container.tag = kApolloTimeOverlayTag;
    container.userInteractionEnabled = NO;
    container.layer.shadowColor = [UIColor blackColor].CGColor;
    container.layer.shadowOpacity = 0.35;
    container.layer.shadowRadius = 10.0;
    container.layer.shadowOffset = CGSizeMake(0, 4);
    container.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:container.bounds cornerRadius:corner].CGPath;

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    card.frame = container.bounds;
    card.layer.cornerRadius = corner;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [accent colorWithAlphaComponent:0.9].CGColor;
    card.contentView.backgroundColor = [accent colorWithAlphaComponent:0.16];
    [container addSubview:card];
    label.frame = CGRectMake(padH, padV, cardW - padH * 2.0, cardH - padV * 2.0);
    [card.contentView addSubview:label];

    // In the cell's coordinate space (so the card moves with the row). Centered
    // over the anchor, just above it; drop below if there's no room above (top of
    // the cell); clamp horizontally to the cell's width.
    CGRect anchor = [host convertRect:anchorRectInWindow fromView:nil];
    CGRect bounds = host.bounds;
    CGFloat originX = CGRectGetMidX(anchor) - cardW / 2.0;
    CGFloat minX = CGRectGetMinX(bounds) + 8.0, maxX = CGRectGetMaxX(bounds) - cardW - 8.0;
    originX = MAX(minX, MIN(originX, MAX(minX, maxX)));
    // Prefer just above the row; drop below if there's no room above. Then keep the
    // whole card INSIDE the cell so a short cell (e.g. a one-line comment) can't push
    // it past the cell's frame, where the neighbouring cell would clip/cover the date.
    CGFloat topLimit = CGRectGetMinY(bounds) + 8.0;
    CGFloat botLimit = CGRectGetMaxY(bounds) - cardH - 8.0;
    CGFloat originY = CGRectGetMinY(anchor) - 8.0 - cardH;
    if (originY < topLimit) originY = CGRectGetMaxY(anchor) + 8.0;
    originY = MAX(topLimit, MIN(originY, MAX(topLimit, botLimit)));
    container.frame = CGRectMake(round(originX), round(originY), cardW, cardH);
    // Ride above the cell's own content regardless of subview/subnode order.
    container.layer.zPosition = 1000.0;

    container.alpha = 0.0;
    container.transform = CGAffineTransformMakeTranslation(0, 6);
    [host addSubview:container];
    sApolloTimeOverlay = container;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        container.alpha = 1.0;
        container.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.35 delay:1.6 options:UIViewAnimationOptionCurveEaseIn animations:^{
        container.alpha = 0.0;
        container.transform = CGAffineTransformMakeTranslation(0, -4);
    } completion:^(BOOL finished) {
        [container removeFromSuperview];
        if (sApolloTimeOverlay == container) sApolloTimeOverlay = nil;
    }];
}

// Padded hit rect for a node in containerView coords, or CGRectNull. Works for
// layer-backed nodes. Padding is modest and roughly symmetric: the info icons —
// score, %, comments, age, edited — sit right next to each other, so generous
// padding would let them steal each other's taps; overlaps are broken by
// nearest-center in ApolloInfoNodeHitAtPoint.
static CGRect ApolloNodeHitRect(ApolloASDisplayNode *node, UIView *containerView) {
    if (!node || node.isHidden || !containerView) return CGRectNull;
    CALayer *layer = nil;
    @try { layer = node.layer; } @catch (__unused id e) {}
    if (!layer || !containerView.layer) return CGRectNull;
    CGRect rect = [layer convertRect:layer.bounds toLayer:containerView.layer];
    if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || CGRectIsInfinite(rect)) return CGRectNull;
    return UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(-9.0, -7.0, -9.0, -7.0));
}

// Resolves the timestamp node. Comment cells expose ageNode directly; post-style
// cells embed PostInfoNode.ageButtonNode.
static ApolloASDisplayNode *ApolloAgeDisplayNodeForCell(id cell) {
    if (!cell) return nil;
    ApolloASDisplayNode *direct = ApolloIvarValueByName(cell, "ageNode");
    if (direct) return direct;
    id postInfoNode = ApolloIvarValueByName(cell, "postInfoNode");
    return postInfoNode ? ApolloIvarValueByName(postInfoNode, "ageButtonNode") : nil;
}

// The "% Upvoted" smiley — post/comments-header only (PostInfoNode); nil elsewhere.
static ApolloASDisplayNode *ApolloPercentageDisplayNodeForCell(id cell) {
    id postInfoNode = ApolloIvarValueByName(cell, "postInfoNode");
    return postInfoNode ? ApolloIvarValueByName(postInfoNode, "percentageLikedButtonNode") : nil;
}

// The edited pencil. Comment cells expose editedIndicatorNode; post-style cells
// embed PostInfoNode.editedButtonNode.
static ApolloASDisplayNode *ApolloEditedDisplayNodeForCell(id cell) {
    ApolloASDisplayNode *direct = ApolloIvarValueByName(cell, "editedIndicatorNode");
    if (direct) return direct;
    id postInfoNode = ApolloIvarValueByName(cell, "postInfoNode");
    return postInfoNode ? ApolloIvarValueByName(postInfoNode, "editedButtonNode") : nil;
}

// Which info icon a point (in cellView coords) lands on — age / % / edited —
// choosing the nearest center when padded regions overlap. Sets *outKind; nil if none.
static ApolloASDisplayNode *ApolloInfoNodeHitAtPoint(id cell, UIView *cellView, CGPoint pt, ApolloInfoKind *outKind) {
    if (!cellView) return nil;
    struct { ApolloInfoKind kind; ApolloASDisplayNode *node; } cands[] = {
        { ApolloInfoKindAge,        ApolloAgeDisplayNodeForCell(cell) },
        { ApolloInfoKindPercentage, ApolloPercentageDisplayNodeForCell(cell) },
        { ApolloInfoKindEdited,     ApolloEditedDisplayNodeForCell(cell) },
    };
    ApolloASDisplayNode *best = nil; ApolloInfoKind bestKind = ApolloInfoKindAge; CGFloat bestDist = CGFLOAT_MAX;
    for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        CGRect rect = ApolloNodeHitRect(cands[i].node, cellView);
        if (CGRectIsNull(rect) || !CGRectContainsPoint(rect, pt)) continue;
        CGFloat d = fabs(pt.x - CGRectGetMidX(rect));
        if (d < bestDist) { bestDist = d; best = cands[i].node; bestKind = cands[i].kind; }
    }
    if (best && outKind) *outKind = bestKind;
    return best;
}

// Idempotent. cancelsTouchesInView swallows the touch so the native % / edited
// button actions never also fire — we present the detail ourselves (or nothing).
static void ApolloInstallInfoTapOnCell(id cell, SEL handler) {
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

// Only acts on our own gesture; claims a touch only when a custom presentation mode
// is enabled and it lands on the age or % icon. The edited pencil is handled
// separately (see below).
static BOOL ApolloInfoTapShouldReceiveTouch(id cell, UIGestureRecognizer *gr, UITouch *touch) {
    if (!objc_getAssociatedObject(gr, kApolloAgeTapMarkerKey)) return YES;
    // Do not let our cancelling recognizer participate when the feature is off.
    // Returning NO preserves Apollo's stock row selection/comment-collapse behavior.
    if (!sInfoRowPopupMode && !sInfoRowOverlayMode) return NO;

    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return NO;
    CGPoint pt = [touch locationInView:cellView];
    ApolloInfoKind hitKind = ApolloInfoKindAge;
    ApolloASDisplayNode *hit = ApolloInfoNodeHitAtPoint(cell, cellView, pt, &hitKind);
    // The edited pencil is a *natively interactive* ApolloButtonNode (target-action
    // -editedButtonTappedWithSender:) — unlike the age/% buttons, which Apollo leaves
    // non-interactive for us to claim. cancelsTouchesInView can't reliably beat the
    // control's own touch-up, so we don't claim edited here; the dedicated
    // editedButtonTappedWithSender: hook below takes it over instead. (Nearest-center
    // still considers edited so an adjacent age/% tap isn't misattributed to it.)
    return (hit != nil && hitKind != ApolloInfoKindEdited);
}

// Shared take-over for the native edited-pencil tap (-editedButtonTappedWithSender:
// on CommentCellNode / CommentsHeaderCellNode). Returns YES when the native alert
// should be suppressed because we presented our own detail. Returns NO when both
// modes are off (preserving Apollo's native alert), or when presentation failed.
static BOOL ApolloHandleEditedButtonTap(id cell, id sender) {
    if (!sInfoRowPopupMode && !sInfoRowOverlayMode) return NO;

    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return NO;
    UIWindow *window = cellView.window;

    // Anchor on the tapped button itself; fall back to the resolved edited node.
    ApolloASDisplayNode *node = [sender respondsToSelector:@selector(layer)] ? (ApolloASDisplayNode *)sender : nil;
    if (!node) node = ApolloEditedDisplayNodeForCell(cell);
    CGRect anchor = CGRectNull;
    CALayer *nl = nil;
    @try { nl = node.layer; } @catch (__unused id e) {}
    if (nl && window) {
        @try { anchor = [nl convertRect:nl.bounds toLayer:window.layer]; } @catch (__unused id e) {}
    }

    id link = ApolloIvarValueByName(cell, "link");
    id comment = ApolloIvarValueByName(cell, "comment");
    if (ApolloPresentInfoDetail(ApolloInfoKindEdited, link, comment, cellView, anchor, window)) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        return YES;
    }
    return NO;
}

static void ApolloInfoTapFired(id cell, UITapGestureRecognizer *tap) {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    // Defensive re-check in case the mode changed after touch-down.
    if (!sInfoRowPopupMode && !sInfoRowOverlayMode) return;

    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return;

    ApolloInfoKind kind = ApolloInfoKindAge;
    ApolloASDisplayNode *node = ApolloInfoNodeHitAtPoint(cell, cellView, [tap locationInView:cellView], &kind);
    if (!node) return;
    // Edited is normally handled by the editedButtonTappedWithSender: hook, so
    // shouldReceiveTouch: returns NO for it and this gesture never claims it. But
    // nearest-center runs twice — at touch-began (shouldReceiveTouch:) and again here
    // at recognition — on locations that can differ by up to the tap slop (~10pt). A
    // tap that began nearest age/% (claimed, cancelsTouchesInView already cancelled the
    // native control) can drift into the edited icon's nearest-center band by
    // recognition. Rather than drop that tap (the native alert can no longer fire),
    // present the edited detail ourselves through the same path.
    if (kind == ApolloInfoKindEdited) { ApolloHandleEditedButtonTap(cell, node); return; }

    UIWindow *window = cellView.window;
    CGRect anchor = CGRectNull;
    CALayer *nl = nil;
    @try { nl = node.layer; } @catch (__unused id e) {}
    if (nl && window) {
        @try { anchor = [nl convertRect:nl.bounds toLayer:window.layer]; } @catch (__unused id e) {}
    }

    id link = ApolloIvarValueByName(cell, "link");
    id comment = ApolloIvarValueByName(cell, "comment");
    if (ApolloPresentInfoDetail(kind, link, comment, cellView, anchor, window)) {
        // Match the vote buttons' native feedback: a light tick on the tap.
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
}

// MARK: - Hooks

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    ApolloInstallInfoTapOnCell(self, @selector(apollo_infoTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloInfoTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_infoTapFired:(UITapGestureRecognizer *)tap {
    ApolloInfoTapFired(self, tap);
}

// Take over the native edited-pencil alert (comment cells). editedButtonTappedWithSender:
// is the ApolloButtonNode's target-action; suppress %orig when we handle it.
- (void)editedButtonTappedWithSender:(id)sender {
    if (ApolloHandleEditedButtonTap(self, sender)) return;
    %orig;
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApolloInstallInfoTapOnCell(self, @selector(apollo_infoTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloInfoTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_infoTapFired:(UITapGestureRecognizer *)tap {
    ApolloInfoTapFired(self, tap);
}

// Take over the native edited-pencil alert (post header — the icon the user tapped).
- (void)editedButtonTappedWithSender:(id)sender {
    if (ApolloHandleEditedButtonTap(self, sender)) return;
    %orig;
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloInstallInfoTapOnCell(self, @selector(apollo_infoTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloInfoTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_infoTapFired:(UITapGestureRecognizer *)tap {
    ApolloInfoTapFired(self, tap);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloInstallInfoTapOnCell(self, @selector(apollo_infoTapFired:));
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloInfoTapShouldReceiveTouch(self, gestureRecognizer, touch);
}

%new
- (void)apollo_infoTapFired:(UITapGestureRecognizer *)tap {
    ApolloInfoTapFired(self, tap);
}

%end
