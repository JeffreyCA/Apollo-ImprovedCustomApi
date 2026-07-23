#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Small export surface over ApolloUserFlair.xm's RDKFlair construction, so other
// modules (currently ApolloOwnCommentFlair.xm) can build flair pieces without
// duplicating the emoji-token parsing or the "emoji pieces must have a nil text"
// rule. Everything else in that translation unit stays static.

// One RDKFlair carrying `text`, via -[RDKFlair initWithRawText:].
id _Nullable ApolloUserFlairBuildTextPiece(NSString *text);

// One RDKFlair emoji run. `text` is deliberately left nil — the native flair cell
// treats any non-nil text as a text run and renders it instead of the image.
id _Nullable ApolloUserFlairBuildEmojiPiece(NSString *emojiLabel, NSString *imageURL);

// Splits a flair_text string into RDKFlair pieces, turning ":token:" into emoji
// runs using the subreddit's cached emoji catalogue. Synchronous and network-free;
// unknown tokens stay as literal text (so a cold emoji cache degrades gracefully).
NSArray *_Nullable ApolloUserFlairBuildPiecesForText(NSString *flairText, NSString *subreddit);

// Ensures the subreddit's emoji catalogue is cached, then runs `completion` (on an
// arbitrary queue). Fires immediately when the catalogue is already warm.
void ApolloUserFlairEnsureEmojisForSubreddit(NSString *subreddit, void (^completion)(void));

NS_ASSUME_NONNULL_END
