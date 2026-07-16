#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const ApolloRichPreviewTranslationDidUpdateNotification;

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node);
NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode);

// Restores a comment/header cell's cached translation synchronously; called by
// the vote-flicker module between Apollo's vote reconfigure (which resets the
// body to the untranslated original) and its synchronous display flush, so the
// original-language text is never measured or painted. Returns YES if a cached
// translation was applied.
BOOL ApolloTranslationReapplySynchronouslyForVoteReconfigure(id cellNode);
