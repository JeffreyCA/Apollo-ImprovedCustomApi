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

// Preserves the exact on-screen translated comment body while Apollo replaces
// its Texture node during a vote. The returned opaque token must be removed
// with ApolloTranslationRemoveVoteBodyCover after the replacement settles.
id ApolloTranslationInstallVoteBodyCover(id cellNode);
void ApolloTranslationRemoveVoteBodyCover(id coverToken);
// Warms the same snapshot cache and briefly presents the identical cover so
// Core Animation commits its layer before a vote. Safe to call for every
// visible comment; it is an exact no-op outside translated mode or when this
// cell/fullname already has a ready cover.
void ApolloTranslationPrimeVoteBodySnapshot(id cellNode);
void ApolloTranslationDiscardVoteBodySnapshot(id cellNode);
