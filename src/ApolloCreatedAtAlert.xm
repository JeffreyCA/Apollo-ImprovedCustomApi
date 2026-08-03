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
// Holding the score on an owned CommentCellNode separately fetches Reddit's author-only
// Comment Insights through the authenticated web session shared by Chat and Polls.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <limits.h>
#include <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommentVoteInsights.h"
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
// A hold on the score of the signed-in user's own comment reveals Reddit's
// author-only Comment Insights without stealing the normal tap-to-vote action.
static const void *kApolloCommentInsightGestureKey = &kApolloCommentInsightGestureKey;

// A normal UILongPressGestureRecognizer loses arbitration to Apollo's existing
// cell-wide action-menu recognizer before its target action fires. Observe the
// raw touch while remaining in .possible—the same proven starting arrangement as
// ApolloVideoHoldSpeed—and suppress only competing long presses whose touch began
// on an eligible comment score. Once the threshold elapses we deliberately enter
// .began so UIKit cancels the underlying score control instead of casting a vote
// when the held finger is released. Quick taps fail this recognizer and stay native.
@interface ApolloCommentInsightTouchRecognizer : UIGestureRecognizer
@property (nonatomic, copy) BOOL (^onTouchDown)(CGPoint point);
@property (nonatomic, copy) void (^onWarmupElapsed)(void);
@property (nonatomic, copy) BOOL (^onHoldElapsed)(void);
@property (nonatomic, copy) void (^onTouchUp)(void);
- (void)apollo_finishCommentInsightTouch;
@end

@implementation ApolloCommentInsightTouchRecognizer {
    BOOL _armed;
    BOOL _holdFired;
    CGPoint _startPoint;
    NSInteger _generation;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (_armed) return;
    _startPoint = [touches.anyObject locationInView:self.view];
    _armed = self.onTouchDown ? self.onTouchDown(_startPoint) : NO;
    _holdFired = NO;
    if (!_armed) return;

    NSInteger generation = ++_generation;
    __weak ApolloCommentInsightTouchRecognizer *weakSelf = self;
    // Once this is clearly more than a very quick vote tap, overlap Reddit's
    // fetch with the remaining hold threshold. The public fetcher's cache and
    // in-flight coalescing make the presentation request effectively free.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloCommentInsightTouchRecognizer *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_armed || strongSelf->_holdFired ||
            strongSelf->_generation != generation) return;
        if (strongSelf.onWarmupElapsed) strongSelf.onWarmupElapsed();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloCommentInsightTouchRecognizer *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_armed || strongSelf->_holdFired ||
            strongSelf->_generation != generation) return;
        // Revalidate at the threshold: the cell can leave the window, be reused,
        // or lose its web session during these 350 ms. Only enter .began (which
        // cancels the native score tap) after the insight UI was actually started.
        BOOL handled = strongSelf.onHoldElapsed ? strongSelf.onHoldElapsed() : NO;
        if (!handled) {
            strongSelf.state = UIGestureRecognizerStateFailed;
            [strongSelf apollo_finishCommentInsightTouch];
            return;
        }
        strongSelf->_holdFired = YES;
        strongSelf.state = UIGestureRecognizerStateBegan;
    });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (!_armed || _holdFired) return;
    CGPoint point = [touches.anyObject locationInView:self.view];
    if (hypot(point.x - _startPoint.x, point.y - _startPoint.y) > 10.0) {
        [self apollo_finishCommentInsightTouch];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.state = _holdFired ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed;
    [self apollo_finishCommentInsightTouch];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.state = _holdFired ? UIGestureRecognizerStateCancelled : UIGestureRecognizerStateFailed;
    [self apollo_finishCommentInsightTouch];
}

- (void)reset {
    [super reset];
    [self apollo_finishCommentInsightTouch];
}

- (void)apollo_finishCommentInsightTouch {
    if (!_armed) return;
    _generation++;
    _armed = NO;
    _holdFired = NO;
    if (self.onTouchUp) self.onTouchUp();
}

@end

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

// Reddit exposes only a fuzzed score (upvotes - downvotes) and a whole-number
// upvote percentage. Reconstruct approximate vote totals from those two values:
//
//     upvotes   = P * score / (2P - 1)
//     downvotes = upvotes - score
//
// The estimate becomes extremely sensitive to Reddit's rounded percentage as P
// approaches 0.5, so only show it at 60% or above. Use the displayed percentage
// rather than any extra precision in the model so the calculation agrees with the
// value the user tapped. Returns NO when only the normal percentage detail should
// be shown.
static BOOL ApolloApproximateVoteCounts(long long score, double displayedPercent,
                                        long long *outUpvotes, long long *outDownvotes) {
    if (displayedPercent < 60 || displayedPercent > 100 || score < 0) return NO;

    double proportion = (double)displayedPercent / 100.0;
    double denominator = 2.0 * proportion - 1.0;
    if (denominator <= 0.0) return NO;

    double upvotes = proportion * (double)score / denominator;
    double downvotes = upvotes - (double)score;
    if (!isfinite(upvotes) || !isfinite(downvotes) || upvotes < 0.0 || downvotes < 0.0 ||
        upvotes >= (double)LLONG_MAX || downvotes >= (double)LLONG_MAX) {
        return NO;
    }

    if (outUpvotes) *outUpvotes = llround(upvotes);
    if (outDownvotes) *outDownvotes = llround(downvotes);
    return YES;
}

static NSString *ApolloFormattedVoteCount(long long count) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.maximumFractionDigits = 0;
    });
    return [formatter stringFromNumber:@(count)] ?: [NSString stringWithFormat:@"%lld", count];
}

static NSString *ApolloFormattedVotePercent(double percent) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.minimumFractionDigits = 0;
        formatter.maximumFractionDigits = 2;
    });
    return [formatter stringFromNumber:@(percent)] ?: [NSString stringWithFormat:@"%.1f", percent];
}

// Posts expose only the fuzzed net score and rounded percentage, so both vote
// totals are estimates. Comment Insights has a separate, source-aware formatter
// below because Reddit can independently provide either an upvote count, a more
// precise ratio, or both.
static BOOL ApolloPostVoteDetailLines(long long score, double pct, BOOL condensed,
                                      NSString **outLine1, NSString **outLine2) {
    if (pct < 0 || pct > 100) return NO;
    NSString *percentText = ApolloFormattedVotePercent(pct);
    *outLine1 = [NSString stringWithFormat:@"%@%% Upvoted", percentText];

    long long upvotes = 0, downvotes = 0;
    BOOL hasCounts = ApolloApproximateVoteCounts(score, pct, &upvotes, &downvotes);
    if (!hasCounts) {
        *outLine2 = condensed ? nil : [NSString stringWithFormat:
            @"%@%% of voters upvoted this post.%@", percentText,
            pct < 60 ? @" Vote totals are not shown below 60% because rounded ratios become unreliable near 50%." : @""];
        return YES;
    }

    NSString *upvoteCount = ApolloFormattedVoteCount(upvotes);
    NSString *downvoteCount = ApolloFormattedVoteCount(downvotes);
    NSString *counts = [NSString stringWithFormat:@"~%@ %@, ~%@ %@",
        upvoteCount, upvotes == 1 ? @"upvote" : @"upvotes",
        downvoteCount, downvotes == 1 ? @"downvote" : @"downvotes"];
    if (condensed) {
        *outLine2 = counts;
    } else {
        long roundedPercent = lround(pct);
        *outLine2 = [NSString stringWithFormat:
            @"%@%% of voters upvoted this post.\n\n%@\n~%ld:%ld upvote to downvote ratio\n\n"
            @"Counts are approximate because Reddit rounds vote ratios and may fuzz vote data.",
            percentText, counts, roundedPercent, 100L - roundedPercent];
    }
    return YES;
}

static BOOL ApolloCommentVoteDetailLines(long long score, ApolloCommentVoteInsight *insight,
                                         BOOL condensed, NSString **outLine1,
                                         NSString **outLine2) {
    if (!insight) return NO;
    double pct = insight.upvotePercent;
    long long reportedUpvotes = insight.reportedUpvotes;
    BOOL hasRatio = isfinite(pct) && pct >= 0.0 && pct <= 100.0;
    BOOL hasReportedUpvotes = reportedUpvotes >= 0;
    if (!hasRatio && !hasReportedUpvotes) return NO;

    NSString *percentText = hasRatio ? ApolloFormattedVotePercent(pct) : nil;
    *outLine1 = hasRatio ? [NSString stringWithFormat:@"%@%% Upvoted", percentText]
                         : @"Comment Upvotes";

    NSString *scoreText = ApolloFormattedVoteCount(score);
    NSString *reportedText = hasReportedUpvotes
        ? ApolloFormattedVoteCount(reportedUpvotes) : nil;
    NSString *reportedPrefix = insight.reportedUpvotesAreAbbreviated ? @"~" : @"";
    NSString *reportedNoun = reportedUpvotes == 1 ? @"upvote" : @"upvotes";
    NSString *snapshotNote = [NSString stringWithFormat:
        @"Apollo currently shows a score of %@. Reddit can fuzz its score and Insights independently, so the figures may not subtract cleanly or remain identical between requests.",
        scoreText];

    if (hasReportedUpvotes && hasRatio && pct >= 60.0) {
        double proportion = pct / 100.0;
        double estimatedDownvotes = (double)reportedUpvotes * (1.0 - proportion) / proportion;
        if (isfinite(estimatedDownvotes) && estimatedDownvotes >= 0.0 &&
            estimatedDownvotes < (double)LLONG_MAX) {
            long long downvotes = llround(estimatedDownvotes);
            NSString *downvoteText = ApolloFormattedVoteCount(downvotes);
            NSString *downvoteNoun = downvotes == 1 ? @"downvote" : @"downvotes";
            if (condensed) {
                *outLine2 = [NSString stringWithFormat:@"%@%@ Reddit %@ • ~%@ calculated %@",
                    reportedPrefix, reportedText, reportedNoun, downvoteText, downvoteNoun];
            } else {
                *outLine2 = [NSString stringWithFormat:
                    @"%@%@ %@ reported by Reddit\n~%@ %@ calculated from %@%%\n\n%@",
                    reportedPrefix, reportedText, reportedNoun, downvoteText, downvoteNoun,
                    percentText, snapshotNote];
            }
            return YES;
        }
    }

    if (hasReportedUpvotes) {
        NSString *reason = !hasRatio
            ? @"Reddit did not provide an upvote ratio, so downvotes cannot be calculated."
            : [NSString stringWithFormat:
                @"Downvotes are not calculated below 60%% because a rounded %@%% ratio is too unstable near 50%%.",
                percentText];
        if (condensed) {
            *outLine2 = [NSString stringWithFormat:@"%@%@ Reddit %@ • downvotes unavailable",
                reportedPrefix, reportedText, reportedNoun];
        } else {
            *outLine2 = [NSString stringWithFormat:@"%@%@ %@ reported by Reddit\n\n%@\n\n%@",
                reportedPrefix, reportedText, reportedNoun, reason, snapshotNote];
        }
        return YES;
    }

    long long upvotes = 0, downvotes = 0;
    if (hasRatio && ApolloApproximateVoteCounts(score, pct, &upvotes, &downvotes)) {
        NSString *upvoteText = ApolloFormattedVoteCount(upvotes);
        NSString *downvoteText = ApolloFormattedVoteCount(downvotes);
        NSString *counts = [NSString stringWithFormat:@"~%@ %@, ~%@ %@",
            upvoteText, upvotes == 1 ? @"upvote" : @"upvotes",
            downvoteText, downvotes == 1 ? @"downvote" : @"downvotes"];
        *outLine2 = condensed ? counts : [NSString stringWithFormat:
            @"%@\n\nReddit supplied the %@%% ratio but not its upvote count, so both totals are estimated from Apollo's fuzzed score of %@.",
            counts, percentText, scoreText];
        return YES;
    }

    *outLine2 = condensed ? @"Vote totals unavailable" : [NSString stringWithFormat:
        @"Reddit reports a %@%% upvote ratio but no upvote count. Totals are not estimated below 60%% because rounded ratios become unreliable near 50%%.",
        percentText];
    return YES;
}


// Data accessors for the three info kinds (createdUTC is declared on RDKComment above).
@interface RDKLink (ApolloInfoAccessor)
@property (nonatomic, readonly) NSDate *edited;
@property (nonatomic, readonly) double upvoteRatio;
@end
@interface RDKComment (ApolloInfoEditedAccessor)
@property (nonatomic, readonly) NSDate *edited;
@property (nonatomic, readonly) NSString *author;
@property (nonatomic, readonly) NSString *fullName;
@property (nonatomic, readonly) long long score;
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
            if (!isfinite(ratio) || ratio < 0.0 || ratio > 1.0) return NO;
            long pct = lround(ratio * 100.0);
            if (![link respondsToSelector:@selector(score)]) return NO;
            return ApolloPostVoteDetailLines((long long)[link score], pct, condensed,
                                             outLine1, outLine2);
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
static NSUInteger sApolloTimeOverlayToken = 0;

static NSUInteger ApolloCurrentInfoOverlayToken(void) {
    return sApolloTimeOverlayToken;
}

static NSUInteger ApolloPresentInfoOverlayWithToken(NSString *line1, NSString *line2,
                                                    UIView *anchorView,
                                                    CGRect anchorRectInWindow) {
    if (line1.length == 0 || !anchorView) return 0;
    NSUInteger presentationToken = ++sApolloTimeOverlayToken;

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
    return presentationToken;
}

void ApolloPresentInfoOverlay(NSString *line1, NSString *line2, UIView *anchorView,
                              CGRect anchorRectInWindow) {
    (void)ApolloPresentInfoOverlayWithToken(line1, line2, anchorView, anchorRectInWindow);
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

// Comment cells expose their arrow + score node directly. Unlike a post's
// percentage node this is a real vote control, so its normal tap remains intact;
// only our dedicated hold recognizer claims it.
static ApolloASDisplayNode *ApolloCommentPointsDisplayNodeForCell(id cell) {
    return ApolloIvarValueByName(cell, "pointsNode");
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

static BOOL ApolloCommentInsightEligibleForCell(id cell) {
    id comment = ApolloIvarValueByName(cell, "comment");
    if (![comment respondsToSelector:@selector(fullName)] ||
        ![comment respondsToSelector:@selector(author)] ||
        ![comment respondsToSelector:@selector(score)]) {
#if APOLLO_SIM_BUILD
        ApolloLog(@"[CommentInsights] ineligible cell %@: comment model/selectors unavailable",
                  NSStringFromClass([cell class]));
#endif
        return NO;
    }
    NSString *fullName = [comment fullName];
    NSString *author = [comment author];
    BOOL eligible = ApolloCommentVoteInsightsEligible(fullName, author);
#if APOLLO_SIM_BUILD
    if (!eligible) {
        ApolloLog(@"[CommentInsights] ineligible comment fullname=%@ author=%@ active=%@",
                  fullName ?: @"(nil)", author ?: @"(nil)",
                  ApolloActiveAccountUsername() ?: @"(nil)");
    }
#endif
    return eligible;
}

static BOOL ApolloBeginCommentInsightHold(id cell);

static BOOL ApolloCommentInsightPointIsEligible(id cell, UIView *cellView, CGPoint point) {
    if (!sInfoRowPopupMode && !sInfoRowOverlayMode) return NO;
    CGRect pointsRect = ApolloNodeHitRect(ApolloCommentPointsDisplayNodeForCell(cell), cellView);
#if APOLLO_SIM_BUILD
    ApolloLog(@"[CommentInsights] hold touch=(%.1f,%.1f) pointsRect=%@",
              point.x, point.y, NSStringFromCGRect(pointsRect));
#endif
    if (CGRectIsNull(pointsRect) || !CGRectContainsPoint(pointsRect, point)) return NO;
    // The web-session lookup reads a keychain item. Keep it off the hot path for
    // every ordinary comment tap by checking the cheap score geometry first.
    return ApolloCommentInsightEligibleForCell(cell);
}

static NSArray<UIGestureRecognizer *> *ApolloCommentInsightSuppressLongPresses(
    UIView *cellView, NSArray<UIView *> **outInteractionViews,
    NSArray<UIContextMenuInteraction *> **outInteractions) {
    NSMutableArray<UIGestureRecognizer *> *suppressed = [NSMutableArray array];
    NSMutableArray<UIView *> *interactionViews = [NSMutableArray array];
    NSMutableArray<UIContextMenuInteraction *> *interactions = [NSMutableArray array];
    // Apollo's competing recognizer can live above the cell, but never touch
    // window-level/system recognizers. Those are unrelated to a comment hold.
    for (UIView *view = cellView; view && ![view isKindOfClass:UIWindow.class]; view = view.superview) {
        for (id<UIInteraction> interaction in [view.interactions copy]) {
            if ([interaction isKindOfClass:UIContextMenuInteraction.class]) {
                [view removeInteraction:interaction];
                [interactionViews addObject:view];
                [interactions addObject:(UIContextMenuInteraction *)interaction];
            }
        }
        for (UIGestureRecognizer *recognizer in [view.gestureRecognizers copy]) {
            if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class] && recognizer.enabled) {
                recognizer.enabled = NO;
                [suppressed addObject:recognizer];
            }
        }
    }
    if (outInteractionViews) *outInteractionViews = interactionViews;
    if (outInteractions) *outInteractions = interactions;
    return suppressed;
}

// Install the score hold. It remains passive for quick taps, then recognizes only
// after the threshold so a completed insight hold cannot also cast a vote.
static void ApolloInstallCommentInsightHoldOnCell(id cell) {
    if (!cell || objc_getAssociatedObject(cell, kApolloCommentInsightGestureKey)) return;
    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    if (!cellView) return;

    ApolloCommentInsightTouchRecognizer *hold = [ApolloCommentInsightTouchRecognizer new];
    hold.cancelsTouchesInView = YES;
    hold.delaysTouchesBegan = NO;
    hold.delaysTouchesEnded = NO;
    __weak id weakCell = cell;
    __weak UIView *weakCellView = cellView;
    __block NSArray<UIGestureRecognizer *> *suppressedRecognizers = nil;
    __block NSArray<UIView *> *suppressedInteractionViews = nil;
    __block NSArray<UIContextMenuInteraction *> *suppressedInteractions = nil;
    __block NSString *warmFullName = nil;
    __block NSString *warmAuthor = nil;
    hold.onTouchDown = ^BOOL(CGPoint point) {
        warmFullName = nil;
        warmAuthor = nil;
        id strongCell = weakCell;
        UIView *strongCellView = weakCellView;
        if (!strongCell || !strongCellView ||
            !ApolloCommentInsightPointIsEligible(strongCell, strongCellView, point)) return NO;
        id comment = ApolloIvarValueByName(strongCell, "comment");
        warmFullName = [[comment fullName] copy];
        warmAuthor = [[comment author] copy];
        suppressedRecognizers = ApolloCommentInsightSuppressLongPresses(
            strongCellView, &suppressedInteractionViews, &suppressedInteractions);
        return YES;
    };
    hold.onWarmupElapsed = ^{
        NSString *fullName = warmFullName;
        NSString *author = warmAuthor;
        if (fullName.length == 0 || author.length == 0) return;
        ApolloFetchCommentVoteInsight(fullName, author,
            ^(__unused ApolloCommentVoteInsight *insight, __unused NSError *error) {});
    };
    hold.onHoldElapsed = ^BOOL{
        id strongCell = weakCell;
        if (strongCell && ApolloBeginCommentInsightHold(strongCell)) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            return YES;
        }
        return NO;
    };
    hold.onTouchUp = ^{
        for (UIGestureRecognizer *recognizer in suppressedRecognizers) recognizer.enabled = YES;
        for (NSUInteger i = 0; i < suppressedInteractions.count; i++) {
            UIContextMenuInteraction *interaction = suppressedInteractions[i];
            if (!interaction.view) [suppressedInteractionViews[i] addInteraction:interaction];
        }
        suppressedRecognizers = nil;
        suppressedInteractionViews = nil;
        suppressedInteractions = nil;
        warmFullName = nil;
        warmAuthor = nil;
    };
    objc_setAssociatedObject(cell, kApolloCommentInsightGestureKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cellView addGestureRecognizer:hold];
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

static void ApolloShowCommentInsightResult(BOOL overlay, UIAlertController *loadingAlert,
                                           id cell, UIView *cellView, CGRect anchor,
                                           NSString *expectedFullName, NSString *expectedAuthor,
                                           ApolloCommentVoteInsight *insight,
                                           long long capturedScore, NSUInteger overlayToken,
                                           NSError *error) {
    id currentComment = ApolloIvarValueByName(cell, "comment");
    NSString *currentFullName = [currentComment respondsToSelector:@selector(fullName)]
        ? [currentComment fullName] : nil;
    BOOL sameComment = currentFullName.length > 0 &&
        [currentFullName caseInsensitiveCompare:expectedFullName] == NSOrderedSame;
    // An overlay belongs to the physical cell. If that cell was recycled while
    // the network request ran, never paint the old comment's result over its new
    // occupant. A popup is its own presented controller and remains valid.
    if (overlay && (!sameComment || !cellView.window ||
                    overlayToken != ApolloCurrentInfoOverlayToken())) return;
    long long score = sameComment && [currentComment respondsToSelector:@selector(score)]
        ? (long long)[currentComment score] : capturedScore;
    NSString *line1 = nil, *line2 = nil;
    if (!ApolloCommentVoteInsightsEligible(expectedFullName, expectedAuthor)) {
        line1 = @"Comment Insights Unavailable";
        line2 = @"The active Reddit account changed while Comment Insights was loading. Try again on the current account.";
    } else if (insight) {
        ApolloCommentVoteDetailLines(score, insight, overlay, &line1, &line2);
    }
    if (line1.length == 0) {
        line1 = @"Comment Insights Unavailable";
        line2 = error.localizedDescription ?: @"Reddit did not return a vote breakdown for this comment.";
    }

    if (overlay) {
        if (cellView.window) ApolloPresentInfoOverlay(line1, line2, cellView, anchor);
        return;
    }
    if (loadingAlert) {
        loadingAlert.title = line1;
        loadingAlert.message = line2;
    }
}

static BOOL ApolloBeginCommentInsightHold(id cell) {
    // Cheap defaults/account revalidation (no keychain read) protects against a
    // cell reload or account switch during the hold threshold.
    if (!ApolloCommentInsightEligibleForCell(cell)) return NO;
    id comment = ApolloIvarValueByName(cell, "comment");
    UIView *cellView = nil;
    @try { cellView = [(ApolloASDisplayNode *)cell view]; } @catch (__unused id e) {}
    UIWindow *window = cellView.window;
    ApolloASDisplayNode *node = ApolloCommentPointsDisplayNodeForCell(cell);
    if (!comment || !cellView || !window || !node) return NO;

    CGRect anchor = CGRectNull;
    CALayer *nodeLayer = nil;
    @try { nodeLayer = node.layer; } @catch (__unused id e) {}
    if (nodeLayer) {
        @try { anchor = [nodeLayer convertRect:nodeLayer.bounds toLayer:window.layer]; } @catch (__unused id e) {}
    }

    BOOL overlay = sInfoRowOverlayMode && !CGRectIsNull(anchor) && !CGRectIsEmpty(anchor);
    UIAlertController *loadingAlert = nil;
    NSUInteger overlayToken = 0;
    if (overlay) {
        overlayToken = ApolloPresentInfoOverlayWithToken(
            @"Loading Comment Insights…", nil, cellView, anchor);
    } else {
        UIViewController *presenter = [window visibleViewController];
        if (!presenter || presenter.isBeingDismissed ||
            [presenter isKindOfClass:UIAlertController.class]) return NO;
        loadingAlert = [UIAlertController alertControllerWithTitle:@"Comment Insights"
            message:@"Loading vote breakdown…" preferredStyle:UIAlertControllerStyleAlert];
        [loadingAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:loadingAlert animated:YES completion:nil];
    }

    NSString *fullName = [[comment fullName] copy];
    NSString *author = [[comment author] copy];
    long long score = [comment score];
    __weak id weakCell = cell;
    __weak UIView *weakCellView = cellView;
    __weak UIAlertController *weakLoadingAlert = loadingAlert;
    ApolloFetchCommentVoteInsight(fullName, author, ^(ApolloCommentVoteInsight *insight, NSError *error) {
        id strongCell = weakCell;
        UIView *strongCellView = weakCellView;
        UIAlertController *strongLoadingAlert = weakLoadingAlert;
        ApolloShowCommentInsightResult(overlay, strongLoadingAlert, strongCell, strongCellView,
                                       anchor, fullName, author, insight, score, overlayToken, error);
    });
    return YES;
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
    ApolloInstallCommentInsightHoldOnCell(self);
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
