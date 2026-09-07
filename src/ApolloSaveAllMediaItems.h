#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A source file, never a thumbnail or a video poster. GIFs remain image files;
// MP4-backed animations are videos so the saver preserves their animation.
@interface ApolloSaveAllMediaItem : NSObject
@property (nonatomic, readonly, copy) NSURL *URL;
@property (nonatomic, readonly) BOOL isVideo;
- (instancetype)initWithURL:(NSURL *)URL isVideo:(BOOL)isVideo NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef void (^ApolloSaveAllMediaResolutionCompletion)(NSArray<ApolloSaveAllMediaItem *> *_Nullable items,
                                                       NSError *_Nullable error);

__BEGIN_DECLS

// Native RDKGallery / RDKLink models. Extraction preserves gallery order and
// fails as a whole if a member cannot be resolved; a partial array must never
// be presented as "all media". The URL-array entry point is for a Swift bridge
// that has already converted MediaPageViewController.foundURLs to NSArray.
// No collection is represented by nil with no error. An existing collection
// with a missing/unsupported member returns nil and an error instead.
NSArray<ApolloSaveAllMediaItem *> *_Nullable ApolloSaveAllMediaItemsFromGallery(id _Nullable gallery, NSError *_Nullable *_Nullable error);
NSArray<ApolloSaveAllMediaItem *> *_Nullable ApolloSaveAllMediaItemsFromLink(id _Nullable link, NSError *_Nullable *_Nullable error);
NSArray<ApolloSaveAllMediaItem *> *_Nullable ApolloSaveAllMediaItemsFromURLs(NSArray<NSURL *> *URLs, NSError *_Nullable *_Nullable error);

// Cheap menu eligibility; performs no network request. Album links may need
// resolution before their exact member count is known.
BOOL ApolloSaveAllMediaLinkHasCollection(id _Nullable link);
BOOL ApolloSaveAllMediaURLIsCollection(NSURL *_Nullable URL);

// Resolve native models first, otherwise fetch the complete Imgur/ImgChest
// album. Completions always arrive on the main queue, including local results.
void ApolloSaveAllMediaResolveLink(id link, ApolloSaveAllMediaResolutionCompletion completion);
void ApolloSaveAllMediaResolveURL(NSURL *URL, ApolloSaveAllMediaResolutionCompletion completion);

__END_DECLS

NS_ASSUME_NONNULL_END
