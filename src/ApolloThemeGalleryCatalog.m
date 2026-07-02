#import "ApolloThemeGalleryCatalog.h"

#import "ApolloThemeGalleryCatalog.gen.h"
#import "ApolloThemeStore.h"

NSArray<NSString *> *ApolloThemeGalleryAllSlugs(void) {
    return ApolloThemeGalleryCatalogGeneratedSlugs();
}

NSDictionary *ApolloThemeGalleryThemeForSlug(NSString *slug) {
    return ApolloThemeGalleryCatalogGeneratedThemeForSlug(slug);
}

void ApolloThemeGalleryRegisterWithStore(void) {
    [ApolloThemeStore registerGalleryResolver:^NSDictionary *(NSString *slug) {
        return ApolloThemeGalleryThemeForSlug(slug);
    }];
}
