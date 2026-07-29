#import <Foundation/Foundation.h>

#import "ApolloLinkPreviewModel.h"

@interface ApolloLinkPreviewCache : NSObject

+ (instancetype)sharedCache;
- (ApolloLinkPreview *)cachedPreviewForURL:(NSURL *)url;
- (BOOL)cachedPreviewIsRichForURL:(NSURL *)url;
- (void)storePreview:(ApolloLinkPreview *)preview forURL:(NSURL *)url;
- (void)removePreviewForURL:(NSURL *)url;
- (void)removePreviewsForRedditUsername:(NSString *)username;
- (void)markNoMetadataForURL:(NSURL *)url;
// Empties the in-memory and disk caches. Triggered from the "Clear Link
// Preview Cache" settings row when entries get poisoned across versions.
- (void)flushCache;
// Walk every entry currently on disk/in memory, ignoring TTL freshness. Used
// once per install to seed ApolloLinkPreviewShapeMemory from previews we have
// already fetched. The block runs OFF the cache's serial queue (on the calling
// thread) so it may safely call back into the cache.
- (void)enumerateStoredPreviewsUsingBlock:(void (^)(NSURL *url, ApolloLinkPreview *preview))block;

@end
