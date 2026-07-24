#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Restores the poster's own user flair on a comment they just submitted.
//
// Reddit's comment-create response (both oauth.reddit.com/api/comment and the
// keyless www.reddit.com equivalent, whose legacy shape ApolloWebJSON.m
// synthesizes into a modern dict) carries no author_flair_* fields, so the
// RDKComment that Apollo splices into the open thread has an empty
// authorFlairRichtext/authorFlairPlaintext and its cell renders no flair pill.
// Everyone else's comments are fine because they arrive through a normal
// listing, which does carry the fields — which is why a pull-to-refresh
// "fixes" it. See ApolloOwnCommentFlair.xm for the full mechanism.

// Called from the MTLJSONAdapter funnel in ApolloFlairColors.xm for every model
// RedditKit deserializes. Harvests the active account's own flair per subreddit
// and, when a submit is armed, backfills the just-posted comment.
void ApolloOwnCommentFlairInspectModel(id model);

// Write-through from the flair editor's save path, so the very next comment in
// that subreddit renders correctly even with a cold cache. `text` of length 0
// records an authoritative "no flair here".
void ApolloOwnCommentFlairRecordSetFlair(NSString *subreddit, NSString *_Nullable text);

// `-[RDKClient setShowUserFlair:subredditName:completion:]`: hiding flair is an
// authoritative empty; showing it again invalidates so the next listing or
// prefetch re-resolves the real value.
void ApolloOwnCommentFlairRecordShowFlair(NSString *subreddit, BOOL show);

NS_ASSUME_NONNULL_END
