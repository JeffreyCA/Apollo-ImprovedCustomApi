#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const ApolloRichPreviewTranslationDidUpdateNotification;

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node);
NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode);

// Settles a vote-reconfigured comment/header cell's body back to its cached
// translation. Called by the vote-flicker module immediately before each of
// its synchronous display flushes, so a flush can never paint the
// untranslated text a vote's node rebuild briefly leaves behind. Exact-gate
// no-op when the body already shows the translation.
BOOL ApolloTranslationReapplySynchronouslyForVoteReconfigure(id cellNode);
