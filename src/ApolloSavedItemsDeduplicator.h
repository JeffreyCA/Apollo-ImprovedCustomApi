#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Removes duplicate Reddit things from one saved-items response while
// preserving the first occurrence and the server's order. Objects without a
// stable Reddit identity are retained because dropping them would be unsafe.
FOUNDATION_EXPORT NSArray *_Nullable ApolloDeduplicateSavedItems(NSArray *_Nullable items);

NS_ASSUME_NONNULL_END
