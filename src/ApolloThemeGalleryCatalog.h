#import <Foundation/Foundation.h>

__BEGIN_DECLS

NS_ASSUME_NONNULL_BEGIN

NSArray<NSString *> *ApolloThemeGalleryAllSlugs(void);
NSDictionary *_Nullable ApolloThemeGalleryThemeForSlug(NSString *slug);
void ApolloThemeGalleryRegisterWithStore(void);

NS_ASSUME_NONNULL_END

__END_DECLS
