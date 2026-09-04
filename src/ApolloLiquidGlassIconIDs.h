#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns the namespaced Classics ID for a legacy, unprefixed base ID, or nil
// when the ID is not one of the Classics choices renamed by the picker layout.
FOUNDATION_EXPORT NSString * _Nullable ApolloLGMigratedClassicsIconID(NSString *iconID);

// Returns the legacy, unprefixed Classics ID for a namespaced base ID, or nil
// when the ID is not one of the renamed Classics choices.
FOUNDATION_EXPORT NSString * _Nullable ApolloLGLegacyClassicsIconID(NSString *iconID);

NS_ASSUME_NONNULL_END
