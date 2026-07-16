// ApolloCommentVoteFlicker
//
// Fixes the one-frame "flicker" of a comment when it is up/down-voted (and on
// any other in-place model update): the whole comment body flashes blank for a
// single frame before redrawing, even though only the score digit + arrow tint
// actually change. Reported on both plain-text and media comments.
//
// ── Mechanism (measured in the sim, not inferred) ──────────────────────────
// A vote delivers the updated RDKComment via the
// "com.christianselig.ModelObjectUpdated" notification to the row's
// -[CommentSectionController modelObjectUpdatedNotificationReceived:], which
// reconfigures the cell in place (byline rebuild + -setNeedsLayout, re-running
// the cell's layoutSpecThatFits:). Texture then re-displays several of the
// cell's text/image nodes ASYNCHRONOUSLY. Instrumenting the display pipeline
// during a real vote showed one of those nodes being committed to screen with
// layer.contents == nil — i.e. the frame renders with that node BLANK, and the
// async redraw only lands on the next frame. That nil-contents commit is the
// flicker. (Whether a given node blanks depends on whether the reconfigure
// clears/replaces it — the byline usually survives, body/text nodes don't —
// but the fix below doesn't need to care which node it is.)
//
// ── Fix ────────────────────────────────────────────────────────────────────
// Make the voted cell finish its (re)display synchronously, inside the same
// frame, so there is never a nil-contents commit:
//   1. neverShowPlaceholders = YES on the cell — Texture then blocks the main
//      thread briefly to complete display of on-screen content instead of
//      committing a placeholder/blank and filling it in a frame later.
//   2. recursivelyEnsureDisplaySynchronously:YES right after the reconfigure,
//      and again on the next main-queue turn — flushes the display passes the
//      reconfigure scheduled (the -setNeedsLayout wave lands a turn later).
// Both selectors exist in Apollo's bundled Texture (verified in the binary).
//
// Scope: ONLY cells that actually receive a model-update notification while
// visible (votes, live edits). Cells never get touched during scrolling, so
// scroll perf is unaffected; the one-off synchronous draw of an already
// visible cell is a sub-millisecond text render on a tap — imperceptible.
//
// Covers both the comment rows (CommentSectionController) and the post header
// in the comments view (CommentsHeaderSectionController) — both flicker the
// same way when voted.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

@interface ASDisplayNode : NSObject
@property (nonatomic) BOOL neverShowPlaceholders;
@property (nonatomic) BOOL displaysAsynchronously;
- (NSArray<ASDisplayNode *> *)subnodes;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)sync;
@end

// Weak set of comment/header cells currently on screen. Only consulted when a
// model-update notification arrives, so the bookkeeping cost is two hash-table
// ops per cell appearance.
static NSHashTable *sApolloVFVisibleCells = nil;

static void ApolloVFTrackCell(id cell, BOOL visible) {
    if (!sApolloVFVisibleCells) sApolloVFVisibleCells = [NSHashTable weakObjectsHashTable];
    if (visible) [sApolloVFVisibleCells addObject:cell];
    else [sApolloVFVisibleCells removeObject:cell];
}

static id ApolloVFIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
}

static NSString *ApolloVFFullName(id model) {
    if (!model || ![model respondsToSelector:@selector(fullName)]) return nil;
    @try {
        NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(model, @selector(fullName));
        return [fn isKindOfClass:[NSString class]] ? fn : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// The visible cell(s) whose model matches the updated one. A vote updates
// exactly one comment; matching by fullname keeps this surgical even when the
// notification fires for unrelated model updates.
static NSArray *ApolloVFCellsForUpdatedModel(id note) {
    id model = [note isKindOfClass:[NSNotification class]] ? [(NSNotification *)note object] : nil;
    NSString *fullName = ApolloVFFullName(model);
    if (fullName.length == 0) return @[];
    NSMutableArray *hits = [NSMutableArray array];
    for (id cell in sApolloVFVisibleCells.allObjects) {
        id m = ApolloVFIvar(cell, "comment") ?: ApolloVFIvar(cell, "link");
        if ([ApolloVFFullName(m) isEqualToString:fullName]) [hits addObject:cell];
    }
    return hits;
}

static void ApolloVFEnsureSynchronousDisplay(NSArray *cells, const char *stage) {
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
            if ([cell respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
                [cell recursivelyEnsureDisplaySynchronously:YES];
            }
        } @catch (__unused NSException *e) {}
    }
    if (cells.count > 0) {
        ApolloLog(@"[VoteFlicker] ensured synchronous display for %lu cell(s) (%s)",
                  (unsigned long)cells.count, stage);
    }
}

// The comment-count bubble in a feed's info row is a tiny layer-backed Texture
// subtree. When a pushed comments controller covers the feed, Texture leaves
// that subtree's display range and discards its backing contents. On an
// interactive pop it normally redraws the bubble asynchronously; UIKit can
// remove the transition snapshot one frame before that redraw commits, which
// is the isolated bubble flicker visible on swipe-back.
//
// Keep this one cheap subtree synchronous for its lifetime. PostInfoNode arms
// the initial subtree when it enters the hierarchy, then re-arms Apollo's
// replacement subtree inside readCommentsUpdatedWithNotification:. This avoids
// navigation timing assumptions and does not make the post body, media, or the
// rest of the feed draw synchronously.
static void ApolloVFStabilizeCommentsInfoNode(ASDisplayNode *node, BOOL flush) {
    if (!node) return;
    @try {
        NSMutableArray<ASDisplayNode *> *pending = [NSMutableArray arrayWithObject:node];
        while (pending.count > 0) {
            ASDisplayNode *current = pending.lastObject;
            [pending removeLastObject];
            if ([current respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                current.neverShowPlaceholders = YES;
            }
            if ([current respondsToSelector:@selector(setDisplaysAsynchronously:)]) {
                current.displaysAsynchronously = NO;
            }
            if ([current respondsToSelector:@selector(subnodes)]) {
                NSArray *children = current.subnodes;
                if (children.count > 0) [pending addObjectsFromArray:children];
            }
        }
        if (flush && [node respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
            [node recursivelyEnsureDisplaySynchronously:YES];
        }
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            ApolloLog(@"[VoteFlicker] comments info subtree armed for synchronous display");
        });
    } @catch (__unused NSException *e) {}
}

static void ApolloVFRealizeUpdatedCommentsInfo(id postInfo, const char *stage) {
    if (!postInfo) return;
    @try {
        ASDisplayNode *commentsInfo = (ASDisplayNode *)ApolloVFIvar(postInfo, "commentsInfoNode");
        if (!commentsInfo) return;
        ApolloVFStabilizeCommentsInfoNode(commentsInfo, NO);
        if ([postInfo respondsToSelector:@selector(setNeedsLayout)]) {
            [postInfo setNeedsLayout];
        }
        if ([postInfo respondsToSelector:@selector(layoutIfNeeded)]) {
            [postInfo layoutIfNeeded];
        }
        ApolloVFStabilizeCommentsInfoNode(commentsInfo, YES);
        if ([postInfo respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
            [postInfo recursivelyEnsureDisplaySynchronously:YES];
        }
        ApolloLog(@"[VoteFlicker] read-comments update realized synchronously (%s)", stage);
    } @catch (__unused NSException *e) {}
}

// Shared handler body for both section-controller hooks: arm the matching
// visible cell(s) before the reconfigure, flush the display wave right after,
// and once more on the next runloop turn (the -setNeedsLayout relayout lands
// there; its re-displays are what commit blank without this).
static void ApolloVFHandleModelUpdate(id note, void (^origCall)(void)) {
    NSArray *cells = ApolloVFCellsForUpdatedModel(note);
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
        } @catch (__unused NSException *e) {}
    }
    origCall();
    if (cells.count == 0) return;
    ApolloVFEnsureSynchronousDisplay(cells, "post-reconfigure");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloVFEnsureSynchronousDisplay(cells, "next-turn");
    });
}

%hook _TtC6Apollo15CommentCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

// CommentsInfoNode's plain -init is intentionally unavailable in Apollo's
// Swift class, and its Texture lifecycle methods are inherited rather than
// class-owned. PostInfoNode does own didEnterHierarchy and already has the
// fully-built commentsInfoNode at that point, making this the reliable place
// to arm the bubble before its first display-range entry.
%hook _TtC6Apollo12PostInfoNode
- (void)didEnterHierarchy {
    %orig;
    ASDisplayNode *commentsInfo = (ASDisplayNode *)ApolloVFIvar(self, "commentsInfoNode");
    ApolloVFStabilizeCommentsInfoNode(commentsInfo, YES);
}

- (void)readCommentsUpdatedWithNotification:(id)notification {
    %orig;
    ApolloVFRealizeUpdatedCommentsInfo(self, "now");
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloVFRealizeUpdatedCommentsInfo(weakSelf, "next-turn");
    });
}
%end

// Feed post cells participate in the foreground heal below (their text blanks
// the same way when the app returns from the background).
%hook _TtC6Apollo17LargePostCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didEnterVisibleState { %orig; ApolloVFTrackCell(self, YES); }
- (void)didExitVisibleState  { %orig; ApolloVFTrackCell(self, NO);  }
%end

%hook _TtC6Apollo24CommentSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    ApolloVFHandleModelUpdate(note, ^{ %orig; });
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    ApolloVFHandleModelUpdate(note, ^{ %orig; });
}
%end

// ── Foreground heal (issue #217's app-switch flicker) ──────────────────────
// Backgrounding makes Texture drop cell backing stores (cells leave the
// visible/display range and free their rendered contents to save memory);
// returning to the app re-displays them ASYNCHRONOUSLY, so every visible
// comment/post body renders BLANK until its redraw lands — measured in the
// sim at over a second of nil-contents commits after didBecomeActive, which
// matches the "text disappears for up to a second" reports. Same nil-contents
// mechanism as the vote flicker, so the same lever fixes it: flush the
// re-displays synchronously during the foreground transition, before the
// live view replaces the system snapshot. Staged passes because cells
// re-enter the visible range at slightly different times across the
// transition (willEnterForeground → didBecomeActive → first frames).
static void ApolloVFForegroundHeal(const char *stage) {
    NSArray *cells = sApolloVFVisibleCells.allObjects;
    if (cells.count == 0) return;
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
                [cell recursivelyEnsureDisplaySynchronously:YES];
            }
        } @catch (__unused NSException *e) {}
    }
    ApolloLog(@"[VoteFlicker] foreground heal: flushed display for %lu cell(s) (%s)",
              (unsigned long)cells.count, stage);
}

%ctor {
    %init;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^heal)(NSNotification *) = ^(__unused NSNotification *n) {
        ApolloVFForegroundHeal("now");
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloVFForegroundHeal("next-turn"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ ApolloVFForegroundHeal("late"); });
    };
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:heal];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:heal];
}
