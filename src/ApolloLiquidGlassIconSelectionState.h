#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Called by the UIApplication icon-setter hook after iOS confirms that a
// native Apollo icon change succeeded. The picker uses this callback to
// commit a pending Standard-pack selection; selection intent alone must not
// erase a confirmed Liquid Glass choice.
FOUNDATION_EXPORT void ApolloLGConfirmSuccessfulSystemIconChange(NSString * _Nullable iconName);

NS_ASSUME_NONNULL_END
