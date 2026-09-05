#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Coalesced onto the main queue after Apollo's native read IDs or last-read
// comment snapshots change. Observe this to refresh existing post presentation
// without rebuilding its surrounding list/carousel. No userInfo is required:
// one notification may represent several post updates or a history clear.
FOUNDATION_EXPORT NSNotificationName const ApolloPostReadStateDidChangeNotification;

// Immutable, queue-ordered snapshot of Apollo's native read IDs (bare IDs,
// e.g. "abc123", oldest first). nil means the tracker/queue is unavailable;
// an empty array means its current history really is empty. Do not substitute
// persisted defaults for an empty result: those may predate a history clear.
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable ApolloReadPostIDsSnapshot(void);

// Apollo's own last-read comment baselines, keyed by bare post ID. A missing
// key means there is no known baseline, not a count of zero. The native tracker
// publishes its JSON to defaults on every save, so this reads live native
// state without accessing an inline Swift OrderedDictionary or keeping a
// second history. For a present baseline, +N is MAX(0, currentTotal - baseline).
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *ApolloLastReadCommentTotalsSnapshot(void);

NS_ASSUME_NONNULL_END
