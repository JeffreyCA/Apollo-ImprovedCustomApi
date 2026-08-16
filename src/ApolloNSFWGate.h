// ApolloNSFWGate.h — see ApolloNSFWGate.xm.
//
// Reddit withholds mature content from third-party API apps unless the signed-in
// account moderates a subreddit. The tweak normally detects that automatically
// (an over-18, popular subreddit whose unfiltered first page comes back empty)
// and offers the one-tap remedy. But a gated account can't *reach* such a
// subreddit by searching either — mature subs are withheld from search on the
// same rule — so anyone who isn't already subscribed to one, or following a
// direct link, would never see the offer. This is the manual way in.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Presents the mature-content explainer with its "Create Private Subreddit…"
/// action, exactly as the automatic sheet does but without naming a subreddit
/// and without any of the once-per-launch/"Don't Show Again" suppression (the
/// user asked for it). Main thread only. Safe to call when nothing is gated —
/// it explains the situation and offers the remedy regardless.
void ApolloNSFWGatePresentUnlockFlow(void);

#ifdef __cplusplus
}
#endif
