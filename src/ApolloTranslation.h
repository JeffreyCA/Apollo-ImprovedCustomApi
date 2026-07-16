#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const ApolloRichPreviewTranslationDidUpdateNotification;

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node);
NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode);
