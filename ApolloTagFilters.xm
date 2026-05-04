// ApolloTagFilters
//
// Hide or blur posts in the Apollo feed based on Reddit's built-in tags
// (NSFW / Spoiler). Per-subreddit overrides take precedence over global
// settings; missing per-sub keys fall back to global.
//
// Strategy: hook the post cell nodes (LargePostCellNode + CompactPostCellNode)
// at didLoad and on layoutSpecThatFits: re-evaluate. If the link is filtered:
//   - "hide" mode → set the cell view hidden + collapse the cell node's
//     calculatedSize to zero (keeps Apollo's data array intact, no
//     pagination desync).
//   - "blur" mode → install a UIVisualEffectView overlay with a small
//     "NSFW" / "Spoiler" pill. First long-press while blurred reveals the
//     cell (next long-press behaves normally). Tap on a blurred cell shows
//     a "Are you sure?" alert before navigating.
//
// Live updates: observers of ApolloTagFiltersChanged trigger a refresh on
// all visible cell nodes.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"

extern NSString *const ApolloTagFiltersChangedNotification;

// MARK: - Minimal AsyncDisplayKit forward declarations

@interface ApolloTagDisplayNode : UIResponder
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly, nullable) UIViewController *closestViewController;
@property (nonatomic) CGSize calculatedSize;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
@end

// MARK: - Helpers

static const void *kApolloTagDecisionKey = &kApolloTagDecisionKey;       // NSString @"hide"|@"blur"|@"none"
static const void *kApolloTagOverlaysKey = &kApolloTagOverlaysKey;        // NSArray<UIVisualEffectView *>
static const void *kApolloTagRevealedKey = &kApolloTagRevealedKey;        // NSNumber BOOL
static const void *kApolloTagAppliedLinkKey = &kApolloTagAppliedLinkKey;  // NSValue (non-retained pointer to current link, used to detect cell reuse)

static id ApolloTagIvarValueByName(id obj, const char *name) {
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

static RDKLink *ApolloTagLinkFromCell(id cell) {
    if (!cell) return nil;
    id v = ApolloTagIvarValueByName(cell, "link");
    if ([v isKindOfClass:objc_getClass("RDKLink")]) return (RDKLink *)v;
    return nil;
}

// Returns @"hide", @"blur", or @"none" given a link and (optional) subreddit context.
// Per-subreddit overrides take precedence over global settings on a per-tag basis;
// mode is also overridable per-sub.
static NSString *ApolloTagFilterDecisionForLink(RDKLink *link) {
    if (!sTagFilterEnabled || !link) return @"none";
    if (![(id)link respondsToSelector:@selector(isNSFW)] && ![(id)link respondsToSelector:@selector(isSpoiler)]) return @"none";

    BOOL isNSFW = NO;
    BOOL isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = link.isSpoiler; } @catch (__unused id e) {}
    if (!isNSFW && !isSpoiler) return @"none";

    NSString *sub = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    NSString *subKey = [sub isKindOfClass:[NSString class]] ? sub.lowercaseString : nil;
    NSDictionary *override = (subKey.length > 0) ? sTagFilterSubredditOverrides[subKey] : nil;

    BOOL filterNSFW = sTagFilterNSFW;
    BOOL filterSpoiler = sTagFilterSpoiler;
    if ([override isKindOfClass:[NSDictionary class]]) {
        id n = override[@"nsfw"];
        if ([n isKindOfClass:[NSNumber class]]) filterNSFW = [(NSNumber *)n boolValue];
        id s = override[@"spoiler"];
        if ([s isKindOfClass:[NSNumber class]]) filterSpoiler = [(NSNumber *)s boolValue];
    }

    BOOL match = (isNSFW && filterNSFW) || (isSpoiler && filterSpoiler);
    if (!match) return @"none";

    // Hide mode was removed; everything filtered now blurs.
    return @"blur";
}

// MARK: - Blur overlays (scoped to content subnodes)

static NSArray<UIVisualEffectView *> *ApolloTagOverlaysForCell(id cell) {
    NSArray *arr = objc_getAssociatedObject(cell, kApolloTagOverlaysKey);
    return [arr isKindOfClass:[NSArray class]] ? arr : nil;
}

static UIView *ApolloTagCellView(id cell) {
    if (!cell) return nil;
    @try {
        ApolloTagDisplayNode *node = (ApolloTagDisplayNode *)cell;
        if (node.isNodeLoaded) return node.view;
    } @catch (__unused id e) {}
    return nil;
}

// Returns the UIView for a given ASDisplayNode-ish ivar value, if loaded.
static UIView *ApolloTagViewForNode(id node) {
    if (!node) return nil;
    if ([node respondsToSelector:@selector(view)]) {
        @try { return [(ApolloTagDisplayNode *)node view]; } @catch (__unused id e) {}
    }
    return nil;
}

// Collect the subviews we want to blur for a given cell.
// Compact cells: thumbnailNode + titleNode (Apollo already blurs spoiler video
//   thumbnails natively; our blur on top is harmless and keeps things consistent).
// Large cells: crosspostNode contains title + rich media + body for both regular
//   posts and crossposts. If unavailable, fall back to titleNode + thumbnailNode.
static NSArray<UIView *> *ApolloTagBlurTargetsForCell(id cell) {
    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    Class compactCls = objc_getClass("_TtC6Apollo19CompactPostCellNode");
    BOOL isCompact = compactCls && [cell isKindOfClass:compactCls];

    if (!isCompact) {
        id cross = ApolloTagIvarValueByName(cell, "crosspostNode");
        UIView *cv = ApolloTagViewForNode(cross);
        if (cv && !cv.isHidden && cv.bounds.size.width > 4 && cv.bounds.size.height > 4) {
            [targets addObject:cv];
            return targets;
        }
    }

    for (NSString *name in @[@"thumbnailNode", @"titleNode"]) {
        id node = ApolloTagIvarValueByName(cell, name.UTF8String);
        UIView *v = ApolloTagViewForNode(node);
        if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) {
            [targets addObject:v];
        }
    }
    return targets;
}

static UIVisualEffectView *ApolloTagBuildBlurOverlay(void) {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *overlay = [[UIVisualEffectView alloc] initWithEffect:effect];
    overlay.userInteractionEnabled = YES;
    overlay.layer.cornerRadius = 8;
    overlay.layer.masksToBounds = YES;
    return overlay;
}

// Pill: NSFW = red bg / white text. SPOILER = grey bg / white text.
// NSFW+SPOILER together: NSFW wins (red).
static UILabel *ApolloTagBuildPillForLink(RDKLink *link) {
    BOOL isNSFW = NO, isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = [(id)link respondsToSelector:@selector(isSpoiler)] ? link.isSpoiler : NO; } @catch (__unused id e) {}
    NSString *text;
    UIColor *bg;
    if (isNSFW) {
        text = @"NSFW";
        bg = [UIColor colorWithRed:0.85 green:0.10 blue:0.10 alpha:0.95];
    } else if (isSpoiler) {
        text = @"SPOILER";
        bg = [UIColor colorWithWhite:0.35 alpha:0.95];
    } else {
        return nil;
    }
    UILabel *pill = [[UILabel alloc] init];
    pill.text = [NSString stringWithFormat:@"  %@  ", text];
    pill.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    pill.textColor = [UIColor whiteColor];
    pill.backgroundColor = bg;
    pill.layer.cornerRadius = 6;
    pill.layer.masksToBounds = YES;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    return pill;
}

static void ApolloTagInstallBlurOverlay(id cell, RDKLink *link) {
    UIView *cellView = ApolloTagCellView(cell);
    if (!cellView) return;

    NSArray<UIView *> *targets = ApolloTagBlurTargetsForCell(cell);
    if (targets.count == 0) {
        // Defer: layout may not have produced subviews yet. We'll retry on next layout pass.
        return;
    }

    NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
    if (existing.count == targets.count) {
        // Reuse existing overlays; just resync frames + ensure pill stays on top.
        for (NSUInteger i = 0; i < targets.count; i++) {
            UIView *target = targets[i];
            UIVisualEffectView *ov = existing[i];
            CGRect f = [target.superview convertRect:target.frame toView:cellView];
            ov.frame = f;
            ov.hidden = NO;
            [cellView bringSubviewToFront:ov];
        }
        return;
    }

    // Tear down and rebuild if count changed.
    for (UIVisualEffectView *ov in existing) [ov removeFromSuperview];

    // Pick the largest target for the pill so it lands on the title area for
    // both layouts (large: crosspostNode body; compact: titleNode is wider than thumbnail).
    NSUInteger pillIndex = 0;
    CGFloat bestArea = 0;
    for (NSUInteger i = 0; i < targets.count; i++) {
        CGSize sz = targets[i].bounds.size;
        CGFloat area = sz.width * sz.height;
        if (area > bestArea) { bestArea = area; pillIndex = i; }
    }

    NSMutableArray<UIVisualEffectView *> *fresh = [NSMutableArray arrayWithCapacity:targets.count];
    for (NSUInteger i = 0; i < targets.count; i++) {
        UIView *target = targets[i];
        UIVisualEffectView *overlay = ApolloTagBuildBlurOverlay();
        CGRect f = [target.superview convertRect:target.frame toView:cellView];
        overlay.frame = f;
        if (i == pillIndex) {
            UILabel *pill = ApolloTagBuildPillForLink(link);
            if (pill) {
                [overlay.contentView addSubview:pill];
                [NSLayoutConstraint activateConstraints:@[
                    [pill.centerXAnchor constraintEqualToAnchor:overlay.contentView.centerXAnchor],
                    [pill.centerYAnchor constraintEqualToAnchor:overlay.contentView.centerYAnchor],
                    [pill.heightAnchor constraintEqualToConstant:24],
                ]];
            }
        }
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:cell action:@selector(apollo_tagFilterCellTapped:)];
        [overlay addGestureRecognizer:tap];
        [cellView addSubview:overlay];
        [cellView bringSubviewToFront:overlay];
        [fresh addObject:overlay];
    }
    objc_setAssociatedObject(cell, kApolloTagOverlaysKey, [fresh copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloTagRemoveBlurOverlay(id cell) {
    NSArray<UIVisualEffectView *> *overlays = ApolloTagOverlaysForCell(cell);
    for (UIVisualEffectView *ov in overlays) [ov removeFromSuperview];
    objc_setAssociatedObject(cell, kApolloTagOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Apply / refresh decision

static void ApolloTagApplyDecisionToCell(id cell) {
    if (!cell) return;
    RDKLink *link = ApolloTagLinkFromCell(cell);
    NSString *decision = ApolloTagFilterDecisionForLink(link);

    // Reset reveal flag if cell was reused for a different link.
    void *appliedLinkPtr = (__bridge void *)link;
    NSValue *prevValue = objc_getAssociatedObject(cell, kApolloTagAppliedLinkKey);
    void *prevPtr = prevValue ? [prevValue pointerValue] : NULL;
    if (prevPtr != appliedLinkPtr) {
        objc_setAssociatedObject(cell, kApolloTagRevealedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kApolloTagAppliedLinkKey,
                                 [NSValue valueWithPointer:appliedLinkPtr],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL revealed = [objc_getAssociatedObject(cell, kApolloTagRevealedKey) boolValue];
    if (revealed) {
        // User long-pressed; treat as no decision until cell is reused.
        decision = @"none";
    }

    objc_setAssociatedObject(cell, kApolloTagDecisionKey, decision, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *cellView = ApolloTagCellView(cell);
    if ([decision isEqualToString:@"blur"]) {
        if (cellView) cellView.hidden = NO;
        ApolloTagInstallBlurOverlay(cell, link);
    } else {
        if (cellView) cellView.hidden = NO;
        ApolloTagRemoveBlurOverlay(cell);
    }
}

// MARK: - Tap / long-press handlers (added via %new on cell hooks)

static UIViewController *ApolloTagPresenterForCell(id cell) {
    if (!cell) return nil;
    @try {
        UIViewController *vc = [(ApolloTagDisplayNode *)cell closestViewController];
        if (vc) return vc;
    } @catch (__unused id e) {}
    UIView *view = ApolloTagCellView(cell);
    UIWindow *window = view.window;
    if (!window) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    return [window visibleViewController];
}

static void ApolloTagRevealCell(id cell) {
    objc_setAssociatedObject(cell, kApolloTagRevealedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloTagDecisionKey, @"none", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<UIVisualEffectView *> *overlays = ApolloTagOverlaysForCell(cell);
    if (overlays.count > 0) {
        [UIView animateWithDuration:0.18 animations:^{
            for (UIVisualEffectView *ov in overlays) ov.alpha = 0.0;
        } completion:^(BOOL finished) {
            ApolloTagRemoveBlurOverlay(cell);
        }];
    }
}

static void ApolloTagPresentConfirmAlertForCell(id cell) {
    UIViewController *presenter = ApolloTagPresenterForCell(cell);
    if (!presenter) {
        // No presenter — just reveal as a fallback.
        ApolloTagRevealCell(cell);
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"View hidden post?"
                                                                   message:@"This post is filtered by your tag-filter settings. Open it anyway?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"View" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // Reveal only — leave navigation to the user's next tap on the now-visible cell.
        ApolloTagRevealCell(cell);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// MARK: - Live updates

static void ApolloTagRefreshAllVisibleCells(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^__block walk)(UIView *) = nil;
        void (^localWalk)(UIView *) = ^(UIView *root) {
            if ([root isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)root;
                @try { [tv reloadData]; } @catch (__unused id e) {}
            }
            for (UIView *sub in root.subviews) walk(sub);
        };
        walk = localWalk;
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            walk(window);
        }
        walk = nil;
    });
}

// MARK: - Cell hooks

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

- (void)layout {
    %orig;
    // Re-apply on every layout (handles cell reuse, link changes, and the
    // common case where subnode views aren't sized yet during didLoad).
    ApolloTagApplyDecisionToCell(self);
}

%new
- (void)apollo_tagFilterCellTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    ApolloTagPresentConfirmAlertForCell(self);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

- (void)layout {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

%new
- (void)apollo_tagFilterCellTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    ApolloTagPresentConfirmAlertForCell(self);
}

%end

// MARK: - Constructor

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloTagFiltersChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        ApolloTagRefreshAllVisibleCells();
    }];
}
