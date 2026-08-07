#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Author-only comment vote insights fetched from Reddit's server-rendered
// /commentstats/t1_<id> page. Reddit does not expose this ratio through the
// legacy OAuth comment model Apollo consumes.
@interface ApolloCommentVoteInsight : NSObject
// -1 when Reddit omitted the ratio but still supplied an upvote count.
@property (nonatomic, readonly) double upvotePercent;
// Explicit upvotes reported by Comment Insights. This value and Apollo's
// separately fetched/fuzzed score can disagree. -1 when omitted.
@property (nonatomic, readonly) long long reportedUpvotes;
// YES when Reddit abbreviated the label (for example, "1.2k upvotes").
@property (nonatomic, readonly) BOOL reportedUpvotesAreAbbreviated;
@end

// YES when `author` is the active account and `fullName` is a comment ID. This
// deliberately does not require a stored web session: an attempted hold can then
// explain how to sign in instead of silently doing nothing.
#ifdef __cplusplus
extern "C" {
#endif

BOOL ApolloCommentVoteInsightsEligible(NSString *_Nullable fullName,
                                       NSString *_Nullable author);

// Fetches (or briefly caches) the signed-in author's server-rendered Comment
// Insights. Completion always runs on the main queue. Reddit supplies the comment
// upvote total and ratio independently; either may be absent after markup or
// product changes, in which case the result still carries the usable field.
void ApolloFetchCommentVoteInsight(NSString *fullName, NSString *author,
                                   void (^completion)(ApolloCommentVoteInsight *_Nullable insight,
                                                      NSError *_Nullable error));

#if APOLLO_SIM_BUILD
// Lightweight fixture coverage for known server-markup variants and partial
// fields. Called by the simulator debug bridge at launch.
BOOL ApolloCommentVoteInsightsRunParserSelfTests(void);
#endif

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
