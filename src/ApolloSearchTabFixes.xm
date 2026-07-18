// ApolloSearchTabFixes.xm
//
// Two Search-tab polish fixes for stock Apollo bugs (Apollo-Reborn issues #646 and #647):
//
// ── #646: suggestions list rests flush against the search bar (legacy/non-Liquid-Glass) ──
//
// Apollo's -[SearchViewController viewDidLoad] hardcodes
//   tableView.contentInset = UIEdgeInsetsMake(-35, 0, 0, 0)      (verified at 0x1002b3d84)
// to swallow the grouped table's automatic first-section top margin. The Trending state
// looks designed anyway because its first section carries the tall labelled
// "TRENDING SUBREDDITS" header — but the search-suggestions state ("Posts with …",
// subreddit autocomplete) has NO first-section header, so on the legacy (non-LG) chrome,
// where that automatic margin is exactly 35pt, the first card rests pixel-flush against
// the bar's hairline. Under Liquid Glass the same table geometry applies, but the floating
// search pill's chrome carries its own transparent breathing room below the pill, so the
// suggestions visibly rest ~19pt clear of it — that's why iOS 26 glass builds look correct
// and only legacy chrome shows the bug (verified A/B in the simulator on both shells). The
// same anchor mismatch is the "rows jump vertically" symptom when clearing/cancelling: the
// table cross-fades between two contents whose first sections rest 35pt apart.
//
// Fix (legacy chrome only — Liquid Glass is already right and must not gain extra air):
// while the search bar has text (suggestions/results showing), rest the first row a fixed
// 16pt below the bar by deriving the inset from the table's *measured* first-row origin
// (the empty self-sizing section-0 header, 35pt today) instead of trusting a constant:
//   inset.top = 16 - firstRowTop     (16 - 35 = -19 as shipped)
// When the text clears (keystroke delete, ⓧ, or Cancel), Apollo's own baseline inset is
// restored, keeping the Trending layout byte-identical to stock.
//
// ── #647: "Random Subreddit" shuffle icon is visibly thinner than its neighbours ──
//
// The random-subreddit asset (24×19pt) is drawn with ~1.0-1.3pt strokes while the
// option-trending icon (26×22pt) right above it uses ~1.7-2.0pt. Rather than swapping the
// glyph (an SF Symbol has a different shape), thicken the original artwork in place with a
// morphological dilation of its alpha mask (CIMorphologyMaximum, radius = scale/3 px ≈
// +0.33pt per side). Same glyph, same weave gaps, matched weight. The asset is referenced
// only by SearchViewController's cell provider (xrefs: 0x1002b3ab4 / 0x1002b4d58 /
// 0x1002b50e8), so patching it at the cell is complete coverage.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo20SearchViewController : UIViewController
@end

// MARK: - #646 helpers

// Visible padding between the search bar's bottom hairline and the first suggestions card.
// Matches what the Liquid Glass variant already shows (~16pt) and the reporter's mock (~14pt).
static const CGFloat kApolloSearchSuggestionsGap = 16.0;

static const void *kApolloSearchBaselineInsetKey = &kApolloSearchBaselineInsetKey;

// The controller's grouped UITableView. SearchViewController subclasses
// ApolloTableViewController, whose `tableView` ivar is ObjC-visible; fall back to a subview
// scan if the ivar ever moves.
static UITableView *ApolloSearchTabTableView(UIViewController *vc) {
    for (Class cls = object_getClass(vc); cls; cls = class_getSuperclass(cls)) {
        Ivar iv = class_getInstanceVariable(cls, "tableView");
        if (iv) {
            id tv = object_getIvar(vc, iv);
            if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
            break;
        }
    }
    for (UIView *v in vc.viewIfLoaded.subviews) {
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    }
    return nil;
}

// Re-anchor the table's top inset for the current mode. `searching` == the bar has text
// (Apollo shows suggestions/results); otherwise Apollo's own baseline inset is restored.
static void ApolloSearchTabApplyTopInset(UIViewController *vc, UISearchBar *bar) {
    UITableView *tv = ApolloSearchTabTableView(vc);
    if (!tv) return;

    // Capture Apollo's baseline (-35 as shipped) the first time through, before we have
    // ever written to the inset, so restores always land on the app's own value.
    NSNumber *baseline = objc_getAssociatedObject(vc, kApolloSearchBaselineInsetKey);
    if (!baseline) {
        baseline = @(tv.contentInset.top);
        objc_setAssociatedObject(vc, kApolloSearchBaselineInsetKey, baseline,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat target = (CGFloat)baseline.doubleValue;
    BOOL searching = bar.text.length > 0;
    if (searching && !IsLiquidGlass() && tv.numberOfSections > 0) {
        // The suggestions section carries an *empty* self-sizing header (Apollo's spacer),
        // so the first visible content is row 0, resting at content-y == that header's
        // height (35pt today). Measure it rather than assume, in case UIKit resizes it.
        CGFloat firstRowTop = [tv numberOfRowsInSection:0] > 0
            ? CGRectGetMinY([tv rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0
                                                                         inSection:0]])
            : CGRectGetHeight([tv rectForHeaderInSection:0]);
        CGFloat padded = kApolloSearchSuggestionsGap - firstRowTop;
        // Never tighter than Apollo's own inset (paranoia against a weird readback).
        if (padded > target) target = padded;
    }

    UIEdgeInsets inset = tv.contentInset;
    if (fabs(inset.top - target) < 1.0) return;   // LG computes ≈ baseline → true no-op

    // Was the table parked at its rest offset? (It always is during the type/clear/cancel
    // transitions this hook runs on; only a mid-scroll change should keep the offset.)
    BOOL parked = tv.contentOffset.y <= -(tv.adjustedContentInset.top - 0.5) &&
                  !tv.isDragging && !tv.isDecelerating;

    CGFloat oldTop = inset.top;
    inset.top = target;
    tv.contentInset = inset;

    // Changing contentInset does not move contentOffset, so re-park at the new rest or the
    // padding stays invisible until the next user scroll.
    if (parked) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, -tv.adjustedContentInset.top)
                    animated:NO];
    }
    ApolloLog(@"[SearchTabFixes] top inset %.1f → %.1f (searching=%d, parked=%d)",
              oldTop, target, searching, parked);
}

// MARK: - #647 helpers

// Two distinct associations: the source image caches its thickened output (render once per
// asset load), while the output itself carries a marker so a re-dequeued cell already
// showing our image is recognized and left alone.
static const void *kApolloThickenedIconCacheKey  = &kApolloThickenedIconCacheKey;
static const void *kApolloThickenedIconMarkerKey = &kApolloThickenedIconMarkerKey;

// Dilate the template icon's alpha by ~scale/3 px per side (≈0.33pt): the 1pt strokes of
// random-subreddit come out ~1.7pt, matching option-trending. Cached on the source UIImage
// so the CI render runs once per asset load.
static UIImage *ApolloThickenedTemplateIcon(UIImage *src) {
    if (!src || !src.CGImage) return nil;
    UIImage *cached = objc_getAssociatedObject(src, kApolloThickenedIconCacheKey);
    if (cached) return cached;

    CIFilter *dilate = [CIFilter filterWithName:@"CIMorphologyMaximum"];
    if (!dilate) return nil;
    [dilate setValue:[CIImage imageWithCGImage:src.CGImage] forKey:kCIInputImageKey];
    [dilate setValue:@(src.scale / 3.0) forKey:@"inputRadius"];
    CIImage *out = dilate.outputImage;
    if (!out) return nil;

    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [ctx createCGImage:out fromRect:out.extent];
    if (!cg) return nil;

    UIImage *thick = [[UIImage imageWithCGImage:cg scale:src.scale orientation:src.imageOrientation]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    CGImageRelease(cg);
    if (thick) {
        objc_setAssociatedObject(src, kApolloThickenedIconCacheKey, thick,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(thick, kApolloThickenedIconMarkerKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SearchTabFixes] thickened random-subreddit icon %@ → %@",
                  NSStringFromCGSize(src.size), NSStringFromCGSize(thick.size));
    }
    return thick;
}

%hook _TtC6Apollo20SearchViewController

// MARK: #646 — re-anchor on every state change that swaps the table's content mode.

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    %orig;
    ApolloSearchTabApplyTopInset(self, bar);
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)bar {
    %orig;
    ApolloSearchTabApplyTopInset(self, bar);
}

// MARK: #647 — swap in the weight-matched icon on the Random Subreddit row.

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    if ([cell.reuseIdentifier isEqualToString:@"RandomSubredditCell"]) {
        UIImage *src = cell.imageView.image;
        // Idempotent: a re-dequeued cell already showing our output is left alone.
        if (src && !objc_getAssociatedObject(src, kApolloThickenedIconMarkerKey)) {
            UIImage *thick = ApolloThickenedTemplateIcon(src);
            if (thick) {
                cell.imageView.image = thick;
                if (cell.imageView.highlightedImage) {
                    cell.imageView.highlightedImage = thick;
                }
            }
        }
    }
    return cell;
}

%end

%ctor {
    %init;
}
