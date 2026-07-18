#import <Foundation/Foundation.h>

// Rehydrates locally confirmed modern Reddit awards into the legacy
// `all_awardings` JSON field Apollo already knows how to decode and display.
// Returns the original data unchanged when there is no matching cache entry.
FOUNDATION_EXPORT NSData *ApolloModernAwardsMergeCachedResponseData(
    NSURLResponse *response, NSData *data);
