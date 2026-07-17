#import <Foundation/Foundation.h>

#import "ApolloCommon.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fix: Apollo silently drops exactly 50 ids on the wire when you bulk-hide (or
// bulk-unhide) more than 50 posts at once — e.g. the "Hide Read Posts" button on
// a feed you've scrolled far through. The hides that get dropped never reach
// Reddit, so those posts reappear on the next refresh even though the app acted
// like it hid them.
//
// Root cause (reverse-engineered in Hopper + confirmed from the disassembly):
// `-[RDKClient hideLinksWithFullnames:completion:]` (0x10003ca70) and the
// byte-identical `-[RDKClient unhideLinksWithFullnames:completion:]` (0x10003d0c8)
// split a bulk hide into 50-id `api/hide` POSTs, but they compute the batch loop
// two different wrong ways at once:
//
//   1. The NUMBER of batches is `fcvtas(count / 50.0)` — a float divide followed
//      by round-to-nearest, ties-away-from-zero. So 51..74 ids round DOWN to 1
//      batch, 75..124 round to 2, 100 → 2, 200 → 4, etc.
//   2. The SIZE of the LAST batch is `count % 50` (every earlier batch is 50).
//
// Together, the total number of ids actually POSTed is
// `50 * (numBatches - 1) + (count % 50)`. Whenever `count > 50` and `count % 50`
// is 0 or in 1..24, the rounded-down batch count is exactly one short, so a full
// 50-id batch is never emitted and those 50 ids are silently lost:
//
//      count   numBatches (fcvtas)   last batch (count%50)   ids POSTed
//      -----   -------------------   --------------------   ----------
//        51            1                     1                   1   (50 dropped)
//        60            1                    10                  10   (50 dropped)
//       100            2                     0                  50   (50 dropped)
//       200            4                     0                 150   (50 dropped)
//        75            2                    25                  75   (correct)
//       125            3                    25                 125   (correct)
//     <= 50      single-batch path (cmp #0x33 / b.lt), always correct
//
// (75/125 happen to work only because `count % 50` lands in 25..49, which offsets
// the off-by-one batch. It is luck, not correctness.) Verified live in the iOS
// simulator by logging every `api/hide` POST: 51 → 1 posted, 60 → 10, 100 → 50,
// 200 → 150; 49/50/75/125 correct.
//
// This is NOT the #641 auto-hide-read-posts bug: the auto-hide flush
// (`ReadPostsTracker.batchHideQueueToReddit`) caps its queue at 50 ids per
// refresh, so it never passes >50 to this method. This bug only bites callers
// that hand the method a single >50-id array — the manual "Hide Read Posts"
// action and any other bulk hide/unhide.
//
// Fix strategy
// ------------
// Rather than try to correct the float-rounding arithmetic in place (it lives
// deep inside the method), we hook both methods and, for arrays of more than 50
// ids, slice the array into contiguous <=50-id chunks ourselves and run each
// chunk through the *original* implementation. Each chunk hits the method's own
// `<= 50` single-batch path (`cmp #0x33` / `b.lt`), which is the known-correct
// route that emits exactly one POST covering every id — so the fixed call emits
// ceil(count / 50) POSTs with no gaps and no overlaps.
//
// Arrays of 50 or fewer ids (and any non-array argument) are passed straight
// through to `%orig` unchanged: that path is already correct, so we never touch
// it.
//
// Completion handling
// -------------------
// The original method, on its multi-batch path, wraps the caller's completion in
// an aggregating block so it fires exactly once after all batches finish. Our
// per-chunk calls to `%orig` would otherwise each fire the completion (the <=50
// path forwards it directly), so to preserve the "fire once" contract we hand the
// caller's real completion to only the LAST chunk and give every earlier chunk a
// no-op block. A no-op `^{}` global block is ABI-safe as a stand-in regardless of
// the real completion's argument signature — its invoke reads only x0 (the block
// itself) and ignores any extra register arguments the network layer passes — and
// being non-nil it can't trip a nil-completion assumption in the enqueue path.
// The task we return is the last chunk's task (the one carrying the real
// completion), matching what the caller expects to associate its completion with.

// RDKClient is always present in Apollo; a forward declaration is enough to
// attach the two hooks. Both selectors take (NSArray *fullnames, block completion)
// and return an id task (ObjC type encoding "@32@0:8@16@?24").
@interface RDKClient : NSObject
@end

// Slice `fullnames` into contiguous <=50-id chunks. Returns nil when no slicing
// is needed — a non-array argument, or 50 or fewer ids — so the caller can just
// fall through to a single unchanged `%orig`.
static NSArray<NSArray *> *ApolloHideBatchSplit(id fullnames) {
    if (![fullnames isKindOfClass:[NSArray class]]) return nil;
    NSArray *all = (NSArray *)fullnames;
    NSUInteger count = all.count;
    if (count <= 50) return nil;

    NSMutableArray<NSArray *> *chunks = [NSMutableArray array];
    for (NSUInteger start = 0; start < count; start += 50) {
        NSUInteger len = MIN((NSUInteger)50, count - start);
        [chunks addObject:[all subarrayWithRange:NSMakeRange(start, len)]];
    }
    return chunks;
}

%hook RDKClient

- (id)hideLinksWithFullnames:(id)fullnames completion:(id)completion {
    NSArray<NSArray *> *chunks = ApolloHideBatchSplit(fullnames);
    if (!chunks) return %orig; // <=50 ids (or non-array): native path is correct.

    ApolloLog(@"[HideBatchFix] hide %lu ids -> %lu batch(es) of <=50 (native drops 50 here)",
              (unsigned long)[(NSArray *)fullnames count], (unsigned long)chunks.count);

    id noop = ^{}; // ABI-safe do-nothing completion for the non-final chunks.
    id lastTask = nil;
    NSUInteger n = chunks.count;
    for (NSUInteger i = 0; i < n; i++) {
        BOOL isLast = (i == n - 1);
        lastTask = %orig(chunks[i], isLast ? completion : noop);
    }
    return lastTask;
}

- (id)unhideLinksWithFullnames:(id)fullnames completion:(id)completion {
    NSArray<NSArray *> *chunks = ApolloHideBatchSplit(fullnames);
    if (!chunks) return %orig; // <=50 ids (or non-array): native path is correct.

    ApolloLog(@"[HideBatchFix] unhide %lu ids -> %lu batch(es) of <=50 (native drops 50 here)",
              (unsigned long)[(NSArray *)fullnames count], (unsigned long)chunks.count);

    id noop = ^{}; // ABI-safe do-nothing completion for the non-final chunks.
    id lastTask = nil;
    NSUInteger n = chunks.count;
    for (NSUInteger i = 0; i < n; i++) {
        BOOL isLast = (i == n - 1);
        lastTask = %orig(chunks[i], isLast ? completion : noop);
    }
    return lastTask;
}

%end

%ctor {
    ApolloLog(@"[HideBatchFix] module loaded (RDKClient bulk hide/unhide >50-id drop fix)");
}
