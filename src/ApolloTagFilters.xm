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

@interface RDKUser : NSObject
@end

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

static const void *kApolloTagDecisionKey = &kApolloTagDecisionKey;        // NSString @"hide"|@"blur"|@"none"
static const void *kApolloTagOverlaysKey = &kApolloTagOverlaysKey;        // NSArray<UIVisualEffectView *>
static const void *kApolloTagRevealedKindsKey = &kApolloTagRevealedKindsKey; // NSMutableSet<NSString *> of revealed kinds (@"title", @"media")
static const void *kApolloTagAppliedLinkKey = &kApolloTagAppliedLinkKey;  // NSValue (non-retained pointer to current link, used to detect cell reuse)
static const void *kApolloTagOverlayKindKey = &kApolloTagOverlayKindKey;  // NSString on overlay: @"title" or @"media"
static const void *kApolloTagNativeObscuredKey = &kApolloTagNativeObscuredKey; // NSNumber BOOL: Apollo's native obscured overlay was seen for this cell+link

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

// MARK: - Blur target geometry
//
// Compact cells: blur thumbnailNode + titleNode separately (these are already
//   the only on-screen content above the action row). The thumbnail overlay
//   is skipped when Apollo natively blurs it: spoilers always, NSFW per the
//   captured blur-mature pref.
//
// Large cells: build TWO overlays — one over the title area, one over the
//   media area — so users can tap-reveal either independently. Each overlay
//   gets its own "kind" (@"title" / @"media"); tapping reveals only that part.
//
//   The media overlay is suppressed whenever Apollo is (or will be) natively
//   obscuring the media, so the two blurs never stack: observed via
//   RichMediaNode.obscuredContentInfoOverlayNode (latched), predicted via the
//   captured blur-mature pref for NSFW (the native overlay materializes late,
//   and waiting for it flashes ours first), plus the legacy spoiler-video
//   heuristic. The title overlay still applies — Apollo never covers titles.
//
//   Coverage uses the actual subnode frames (richMediaNode / thumbnailNode /
//   crosspostNode→richMediaNode) extended horizontally to the cell width so
//   gallery thumbnails that scroll past the cell edges don't bleed through.

// Returns the title subnode's view, if loaded and visible.
static UIView *ApolloTagTitleViewForCell(id cell) {
    id node = ApolloTagIvarValueByName(cell, "titleNode");
    UIView *v = ApolloTagViewForNode(node);
    if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) return v;
    return nil;
}

// Returns the media subnode's view (gallery / image / video container) and
// optionally the underlying richMediaNode (for video detection). Tries the
// richMediaNode-bearing ivars first, then falls back to thumbnailNode.
static UIView *ApolloTagMediaViewForCell(id cell, id *outRichMediaNode) {
    if (outRichMediaNode) *outRichMediaNode = nil;
    id richMedia = ApolloTagIvarValueByName(cell, "richMediaNode");
    if (!richMedia) {
        id cross = ApolloTagIvarValueByName(cell, "crosspostNode");
        if (cross) richMedia = ApolloTagIvarValueByName(cross, "richMediaNode");
    }
    if (richMedia) {
        UIView *v = ApolloTagViewForNode(richMedia);
        if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) {
            if (outRichMediaNode) *outRichMediaNode = richMedia;
            return v;
        }
    }
    // Large Thumbnails / link-card variants: media lives on thumbnailNode.
    id thumb = ApolloTagIvarValueByName(cell, "thumbnailNode");
    UIView *tv = ApolloTagViewForNode(thumb);
    if (tv && !tv.isHidden && tv.bounds.size.width > 4 && tv.bounds.size.height > 4) {
        return tv;
    }
    return nil;
}

// Detect whether the rich media node currently represents a video. Apollo
// populates the videoNode ivar on RichMediaNode for v.redd.it / Streamable /
// hosted video / GIF posts.
static BOOL ApolloTagMediaIsVideo(id richMediaNode) {
    if (!richMediaNode) return NO;
    id vn = ApolloTagIvarValueByName(richMediaNode, "videoNode");
    return vn != nil;
}

// Captured Reddit account pref "Blur mature (18+) images and media",
// PER ACCOUNT. Apollo parses pref_no_profanity from self /me.json (and self
// /about.json) into RDKUser.noProfanity via Mantle. With multiple accounts
// added, Apollo materializes an RDKUser for EVERY stored account (switcher
// refreshes, session restores) — a single last-writer-wins global held
// whichever account happened to parse most recently, which is wrong for the
// signed-in account whenever two accounts' prefs disagree, and the 0↔1
// ping-pong re-ran the visible-cell refresh once per parse. Captures are
// keyed by lowercased username and decisions resolve against the ACTIVE
// account. Effective value is -1 (unknown) until the active account's pref
// is captured; some sessions never capture it at all (web-JSON/cookie
// identity synthesizes the account without a /me fetch), so unknown must NOT
// suppress our cover (see below). All state is main-thread confined: the
// Mantle setter can fire on background parse queues mid-init, so captures
// hop to main (where the parsed object is fully populated); decisions run
// from cell didLoad/layout on main.
static NSMutableDictionary<NSString *, NSNumber *> *sTagNoProfanityByUser = nil;
static NSString *sTagActiveUsername = nil;
static NSInteger sTagEffectiveNoProfanity = -1;

static void ApolloTagRefreshAllVisibleCells(void);

static NSString *ApolloTagNormalizedUsername(id userObject) {
    NSString *name = nil;
    if ([userObject respondsToSelector:@selector(username)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(userObject, @selector(username));
        if ([v isKindOfClass:[NSString class]]) name = v;
    }
    if (name.length == 0 && [userObject respondsToSelector:@selector(name)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(userObject, @selector(name));
        if ([v isKindOfClass:[NSString class]]) name = v;
    }
    return name.length > 0 ? [name lowercaseString] : nil;
}

// Live lookup for sessions restored with a signed-in user before any
// -[RDKClient setCurrentUser:] fires under our hook.
static NSString *ApolloTagLiveActiveUsername(void) {
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedClient)]) return nil;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient));
    if (!client || ![client respondsToSelector:@selector(currentUser)]) return nil;
    id currentUser = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    return currentUser ? ApolloTagNormalizedUsername(currentUser) : nil;
}

// Main thread only. Re-resolves the active account's captured pref; on an
// EFFECTIVE change (capture for the active account, or an account switch)
// re-evaluates visible cells — a statically-visible feed gets no layout pass
// of its own when /me lands or the account flips.
static void ApolloTagRecomputeEffectiveNoProfanity(void) {
    if (sTagActiveUsername.length == 0) sTagActiveUsername = ApolloTagLiveActiveUsername();
    NSNumber *captured = sTagActiveUsername.length > 0 ? sTagNoProfanityByUser[sTagActiveUsername] : nil;
    NSInteger effective = captured ? (captured.boolValue ? 1 : 0) : -1;
    if (effective == sTagEffectiveNoProfanity) return;
    sTagEffectiveNoProfanity = effective;
    ApolloLog(@"[TagFilters] Effective pref_no_profanity=%ld for u/%@ (blur mature media)",
              (long)effective, sTagActiveUsername ?: @"(unknown)");
    ApolloTagRefreshAllVisibleCells();
}

// Predicts Apollo's native NSFW obscuring for a link, so the tweak's overlay
// can stay out of the way from the FIRST layout pass (the native overlay node
// materializes late — waiting for it flashes our overlay first). Requires a
// captured YES: treating unknown as "will blur" would drop BOTH covers in
// sessions where the pref never parses (web-JSON identity) — Apollo's user
// object exists with noProfanity NO, so no native overlay ever appears. The
// conservative default costs only a brief launch-window double-blur.
static BOOL ApolloTagNativeWillBlurNSFW(BOOL isNSFW) {
    return isNSFW && sTagEffectiveNoProfanity == 1;
}

// Apollo's native obscured overlay ("NSFW / Spoiler — tap to view") lives on
// RichMediaNode.obscuredContentInfoOverlayNode, created iff the node was
// configured obscured — spoilers always, NSFW per the blur-mature pref (with
// a default-blur while Apollo's user object hasn't loaded). LATCHED per
// cell+link: the native reveal reconfigures the node with the ivar nil, and
// re-adding our overlay right after the user tapped through Apollo's own
// gate would gate them twice.
//
// latchTrusted=NO for NSFW-only links once the pref is known OFF: any native
// overlay seen then was launch-window default-blur residue, and when Apollo
// reconfigures the cell un-obscured the latch would otherwise strand the
// media with NEITHER gate. (Spoiler-tagged links keep the latch — their
// native blur is pref-independent, so a vanished overlay there is a real
// user reveal.)
static BOOL ApolloTagMediaNativelyObscured(id cell, id richMediaNode, BOOL latchTrusted) {
    id overlay = richMediaNode
        ? ApolloTagIvarValueByName(richMediaNode, "obscuredContentInfoOverlayNode") : nil;
    if (!latchTrusted) {
        objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return overlay != nil;
    }
    NSNumber *latched = objc_getAssociatedObject(cell, kApolloTagNativeObscuredKey);
    if ([latched boolValue]) return YES;
    if (!overlay) return NO;
    objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Returns an array of NSDictionary entries: @{ @"rect": NSValue<CGRect>, @"kind": NSString }.
// Rects are in cellView coordinates. `kind` is one of @"title" or @"media".
static NSArray<NSDictionary *> *ApolloTagBlurEntriesForCell(id cell, RDKLink *link) {
    UIView *cellView = ApolloTagCellView(cell);
    if (!cellView || cellView.bounds.size.width < 8 || cellView.bounds.size.height < 8) return @[];

    Class compactCls = objc_getClass("_TtC6Apollo19CompactPostCellNode");
    BOOL isCompact = compactCls && [cell isKindOfClass:compactCls];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    if (isCompact) {
        // Compact: blur titleNode + (usually) thumbnailNode at their actual
        // frames. Pill only on the title (the thumbnail is too small to wear
        // it). The thumbnail overlay is skipped when Apollo already blurs it
        // natively — spoilers always, NSFW per the predicted blur-mature pref
        // (compact cells have no richMediaNode overlay ivar to observe).
        BOOL compactIsNSFW = NO, compactIsSpoiler = NO;
        @try { compactIsNSFW = link.isNSFW; } @catch (__unused id e) {}
        @try { compactIsSpoiler = link.isSpoiler; } @catch (__unused id e) {}
        BOOL skipCompactThumb = (!compactIsNSFW && compactIsSpoiler)
            || ApolloTagNativeWillBlurNSFW(compactIsNSFW);
        for (NSString *name in @[@"thumbnailNode", @"titleNode"]) {
            BOOL isTitle = [name isEqualToString:@"titleNode"];
            if (!isTitle && skipCompactThumb) continue;
            id node = ApolloTagIvarValueByName(cell, name.UTF8String);
            UIView *v = ApolloTagViewForNode(node);
            if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) {
                CGRect f = [v.superview convertRect:v.frame toView:cellView];
                NSString *kind = isTitle ? @"title" : @"media";
                [entries addObject:@{ @"rect": [NSValue valueWithCGRect:f],
                                      @"kind": kind,
                                      @"corner": @8.0,
                                      @"pill": @(isTitle) }];
            }
        }
        return entries;
    }

    // Large path.
    BOOL isNSFW = NO, isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = link.isSpoiler; } @catch (__unused id e) {}

    UIView *titleView = ApolloTagTitleViewForCell(cell);
    id richMediaNode = nil;
    UIView *mediaView = ApolloTagMediaViewForCell(cell, &richMediaNode);

    // Title overlay: title's frame stretched to full cell width so any
    // trailing tag pills are also covered. Rounded corners look right here
    // because the title sits inside the card padding.
    if (titleView) {
        CGRect tf = [titleView.superview convertRect:titleView.frame toView:cellView];
        const CGFloat vPad = 4.0;
        CGRect rect = CGRectMake(0,
                                 MAX(0, CGRectGetMinY(tf) - vPad),
                                 cellView.bounds.size.width,
                                 CGRectGetHeight(tf) + 2 * vPad);
        if (rect.size.width >= 40 && rect.size.height >= 16) {
            [entries addObject:@{ @"rect": [NSValue valueWithCGRect:rect],
                                  @"kind": @"title",
                                  @"corner": @8.0,
                                  @"pill": @YES }];
        }
    }

    // Media overlay: skipped when Apollo is already natively obscuring this
    // media (obscuredContentInfoOverlayNode present — covers NSFW under the
    // account's blur-mature pref and spoilers alike; latched so the native
    // reveal isn't followed by our overlay), plus the legacy spoiler-video
    // heuristic for configurations where the ivar isn't observable yet.
    // Square corners — the media area runs edge-to-edge and any rounding
    // leaves a sliver of the underlying image visible in the corners.
    BOOL latchTrusted = isSpoiler || sTagEffectiveNoProfanity != 0;
    BOOL skipMedia = ApolloTagMediaNativelyObscured(cell, richMediaNode, latchTrusted)
        || (richMediaNode && ApolloTagNativeWillBlurNSFW(isNSFW))
        || (!isNSFW && isSpoiler && ApolloTagMediaIsVideo(richMediaNode));
    if (!skipMedia && mediaView) {
        CGRect mf = [mediaView.superview convertRect:mediaView.frame toView:cellView];
        // Stretch horizontally to full cell width so a horizontally-scrollable
        // gallery doesn't bleed past the overlay edges.
        CGRect rect = CGRectMake(0,
                                 CGRectGetMinY(mf),
                                 cellView.bounds.size.width,
                                 CGRectGetHeight(mf));
        if (rect.size.width >= 40 && rect.size.height >= 40) {
            [entries addObject:@{ @"rect": [NSValue valueWithCGRect:rect],
                                  @"kind": @"media",
                                  @"corner": @0.0,
                                  @"pill": @YES }];
        }
    }

    return entries;
}

static UIVisualEffectView *ApolloTagBuildBlurOverlay(CGFloat cornerRadius) {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *overlay = [[UIVisualEffectView alloc] initWithEffect:effect];
    overlay.userInteractionEnabled = YES;
    overlay.layer.cornerRadius = cornerRadius;
    overlay.layer.masksToBounds = (cornerRadius > 0);
    return overlay;
}

// Returns the set of kinds (@"title" / @"media") the user has individually
// revealed on this cell. Lazily created.
static NSMutableSet<NSString *> *ApolloTagRevealedKindsForCell(id cell, BOOL create) {
    NSMutableSet *set = objc_getAssociatedObject(cell, kApolloTagRevealedKindsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(cell, kApolloTagRevealedKindsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
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

    NSArray<NSDictionary *> *entries = ApolloTagBlurEntriesForCell(cell, link);
    if (entries.count == 0) {
        // Defer: layout may not have produced subviews yet. We'll retry on next layout pass.
        return;
    }

    // Suppress kinds the user has already individually revealed.
    NSSet<NSString *> *revealedKinds = [ApolloTagRevealedKindsForCell(cell, NO) copy] ?: [NSSet set];
    if (revealedKinds.count > 0) {
        NSMutableArray<NSDictionary *> *filtered = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSDictionary *e in entries) {
            if (![revealedKinds containsObject:e[@"kind"]]) [filtered addObject:e];
        }
        entries = filtered;
    }
    if (entries.count == 0) {
        // Everything is revealed — tear down anything we still have on the cell.
        NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
        for (UIVisualEffectView *ov in existing) [ov removeFromSuperview];
        objc_setAssociatedObject(cell, kApolloTagOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Reuse path: same set of kinds → just resync frames.
    NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
    BOOL canReuse = (existing.count == entries.count);
    if (canReuse) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSString *existingKind = objc_getAssociatedObject(existing[i], kApolloTagOverlayKindKey);
            if (![existingKind isEqualToString:entries[i][@"kind"]]) { canReuse = NO; break; }
        }
    }
    if (canReuse) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            UIVisualEffectView *ov = existing[i];
            ov.frame = [entries[i][@"rect"] CGRectValue];
            ov.hidden = NO;
            [cellView bringSubviewToFront:ov];
        }
        return;
    }

    // Tear down and rebuild.
    for (UIVisualEffectView *ov in existing) [ov removeFromSuperview];

    NSMutableArray<UIVisualEffectView *> *fresh = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSUInteger i = 0; i < entries.count; i++) {
        NSDictionary *entry = entries[i];
        CGFloat corner = [entry[@"corner"] doubleValue];
        UIVisualEffectView *overlay = ApolloTagBuildBlurOverlay(corner);
        overlay.frame = [entry[@"rect"] CGRectValue];
        objc_setAssociatedObject(overlay, kApolloTagOverlayKindKey, entry[@"kind"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([entry[@"pill"] boolValue]) {
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
    // Feature off: skip the link ivar-walk + associated-object churn this
    // otherwise pays on every post-cell layout during scrolling. A cell that
    // still carries state from when the filter WAS on gets the same teardown
    // the "none" decision below performs (a nil decision reads as "none"
    // everywhere it is consumed).
    if (!sTagFilterEnabled) {
        if (objc_getAssociatedObject(cell, kApolloTagOverlaysKey) ||
            objc_getAssociatedObject(cell, kApolloTagDecisionKey)) {
            objc_setAssociatedObject(cell, kApolloTagDecisionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *cellView = ApolloTagCellView(cell);
            if (cellView) cellView.hidden = NO;
            ApolloTagRemoveBlurOverlay(cell);
        }
        return;
    }
    RDKLink *link = ApolloTagLinkFromCell(cell);
    NSString *decision = ApolloTagFilterDecisionForLink(link);

    // Reset per-overlay revealed kinds if cell was reused for a different link.
    void *appliedLinkPtr = (__bridge void *)link;
    NSValue *prevValue = objc_getAssociatedObject(cell, kApolloTagAppliedLinkKey);
    void *prevPtr = prevValue ? [prevValue pointerValue] : NULL;
    if (prevPtr != appliedLinkPtr) {
        objc_setAssociatedObject(cell, kApolloTagRevealedKindsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kApolloTagAppliedLinkKey,
                                 [NSValue valueWithPointer:appliedLinkPtr],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
        for (UIWindow *w in ApolloAllWindows()) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    return [window visibleViewController];
}

// Reveal a single overlay (by kind). The kind is added to the cell's revealed
// set so cell-reuse / re-layout passes won't put it back. Other overlays on the
// same cell remain.
static void ApolloTagRevealOverlay(id cell, UIVisualEffectView *overlay, NSString *kind) {
    if (kind.length > 0) {
        NSMutableSet *revealed = ApolloTagRevealedKindsForCell(cell, YES);
        [revealed addObject:kind];
    }
    if (overlay) {
        [UIView animateWithDuration:0.18 animations:^{
            overlay.alpha = 0.0;
        } completion:^(BOOL finished) {
            [overlay removeFromSuperview];
            // Drop it from the cached overlays array.
            NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
            if (existing) {
                NSMutableArray *remaining = [existing mutableCopy];
                [remaining removeObject:overlay];
                objc_setAssociatedObject(cell, kApolloTagOverlaysKey,
                                         remaining.count > 0 ? [remaining copy] : nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            // If nothing's covered anymore, downgrade decision so future
            // layouts don't re-evaluate as "blur" pointlessly.
            NSArray<UIVisualEffectView *> *after = ApolloTagOverlaysForCell(cell);
            if (after.count == 0) {
                objc_setAssociatedObject(cell, kApolloTagDecisionKey, @"none", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }];
    }
}

static void ApolloTagPresentConfirmAlertForOverlay(id cell, UIVisualEffectView *overlay) {
    NSString *kind = objc_getAssociatedObject(overlay, kApolloTagOverlayKindKey);
    UIViewController *presenter = ApolloTagPresenterForCell(cell);
    if (!presenter) {
        // No presenter — just reveal as a fallback.
        ApolloTagRevealOverlay(cell, overlay, kind);
        return;
    }

    NSString *title = @"View hidden post?";
    NSString *message = @"This post is filtered by your tag-filter settings. Reveal it anyway?";
    if ([kind isEqualToString:@"title"]) {
        message = @"Reveal the title of this filtered post?";
    } else if ([kind isEqualToString:@"media"]) {
        message = @"Reveal the media of this filtered post?";
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reveal" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        ApolloTagRevealOverlay(cell, overlay, kind);
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
        for (UIWindow *window in ApolloAllWindows()) {
            walk(window);
        }
        walk = nil;
    });
}

// MARK: - Cell hooks

// Captures a per-account blur-mature pref as Apollo parses it from /me.json
// (Mantle key path data.pref_no_profanity → this setter). A pref change made
// on Reddit's side flows in on the next /me refresh. The capture hops to
// main because Mantle can call this setter mid-init on a background parse
// queue — on main the object's username is populated and all TagFilters
// state is main-confined (the old direct call also walked UIWindows from the
// parse thread). Cell refresh happens only when the ACTIVE account's
// effective value changes, inside the recompute.
%hook RDKUser

- (void)setNoProfanity:(BOOL)value {
    %orig;
    id parsedUser = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *username = ApolloTagNormalizedUsername(parsedUser);
        if (username.length == 0) return;  // uncaptured stays conservative (-1)
        if (!sTagNoProfanityByUser) sTagNoProfanityByUser = [NSMutableDictionary dictionary];
        NSNumber *previous = sTagNoProfanityByUser[username];
        if (!previous || previous.boolValue != value) {
            sTagNoProfanityByUser[username] = @(value);
            ApolloLog(@"[TagFilters] Captured pref_no_profanity=%d for u/%@ (blur mature media)", value, username);
        }
        ApolloTagRecomputeEffectiveNoProfanity();
    });
}

%end

// Account switches move the effective pref to the new account's captured
// value (or back to unknown if it was never captured for them).
%hook RDKClient

- (void)setCurrentUser:(id)user {
    %orig;
    id newUser = user;
    dispatch_async(dispatch_get_main_queue(), ^{
        sTagActiveUsername = newUser ? ApolloTagNormalizedUsername(newUser) : nil;
        ApolloTagRecomputeEffectiveNoProfanity();
    });
}

%end

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
    UIVisualEffectView *overlay = nil;
    if ([tap.view isKindOfClass:[UIVisualEffectView class]]) overlay = (UIVisualEffectView *)tap.view;
    ApolloTagPresentConfirmAlertForOverlay(self, overlay);
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
    UIVisualEffectView *overlay = nil;
    if ([tap.view isKindOfClass:[UIVisualEffectView class]]) overlay = (UIVisualEffectView *)tap.view;
    ApolloTagPresentConfirmAlertForOverlay(self, overlay);
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
