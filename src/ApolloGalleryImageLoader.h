// ApolloGalleryImageLoader.h
//
// Shared image fetch + decode for Gallery View (grid tiles and the fullscreen
// viewer). Kept separate from ApolloGalleryFeed so the network/JSON layer has
// no UIKit dependency.
//
// Three things the grid and viewer both need and shouldn't each reimplement:
//   • a bounded in-memory image cache, so scrolling back up doesn't re-download;
//   • animated-GIF playback (UIImage's plain +imageWithData: shows frame 0 only,
//     which is why a GIF looks like a still everywhere it isn't handled);
//   • the original bytes, so Save/Share exports the real file — a GIF stays a
//     GIF instead of being flattened by a re-encode.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Opaque handle for an in-flight load; hold it to cancel when a cell is reused
// or a viewer page scrolls far enough away. Several requests for the same URL
// share one download, so cancelling one never strands the others.
@interface ApolloGalleryImageRequest : NSObject
- (void)cancel;
// 0…1 for the underlying download, for a determinate progress bar. Sampled by
// the caller (the viewer polls it on a timer) rather than pushed.
@property (nonatomic, readonly) double progressFraction;
@end

// One decoded picture. A still carries only `image`; an animated GIF also
// carries the FLAnimatedImage that streams its frames.
//
// GIFs are NOT decoded into a UIImage frame array. +[UIImage
// animatedImageWithImages:duration:] holds every frame as a full-size bitmap
// and UIImageView materialises the lot on the first loop, so cost is
// frames x width x height x 4 with no ceiling — a 2.2 MB, 400-frame 1280x720
// GIF measured at +1414 MB resident, which is what jetsam killed in issue
// #1000. FLAnimatedImage (already bundled inside Apollo, so no new dependency)
// keeps the compressed data plus a small self-sizing frame window and decodes
// ahead on its own queue: the same GIF measured at +17 MB, full resolution,
// no frames dropped.
@interface ApolloGalleryDecodedImage : NSObject
// Always present: the still frame. For an animation this is the poster frame,
// which is what sizes the zoom geometry and backs a PNG re-encode for Save.
@property (nonatomic, strong, readonly) UIImage *image;
// The FLAnimatedImage to hand to an FLAnimatedImageView, or nil for a still.
// Typed `id` because the tweak resolves the class at runtime out of Apollo's
// own bundled framework rather than linking against it.
@property (nonatomic, strong, readonly, nullable) id animatedImage;
@end

@interface ApolloGalleryImageLoader : NSObject

+ (instancetype)sharedLoader;

// Cached full-tier decode for `url`, or nil. Synchronous and cheap — call it
// before starting a load so a warm page renders in the same runloop turn (no
// flash).
- (nullable ApolloGalleryDecodedImage *)cachedImageForURL:(NSURL *)url;
// Cached THUMBNAIL-tier decode for `url` (see -loadThumbnailAtURL:…), or nil.
- (nullable UIImage *)cachedThumbnailForURL:(NSURL *)url;

// Original downloaded bytes for `url` while they're still cached, for Save and
// Share. nil once evicted; callers fall back to re-encoding the UIImage.
- (nullable NSData *)cachedDataForURL:(NSURL *)url;

// Downloads (or returns from cache) and decodes at full size. `completion`
// always runs on the main thread, and is skipped entirely if the request was
// cancelled. `progress` is optional and also runs on the main thread.
// Animated GIFs come back with `decoded.animatedImage` set (see
// ApolloGalleryDecodedImage).
- (ApolloGalleryImageRequest *)loadImageAtURL:(NSURL *)url
                                     progress:(nullable void (^)(double fraction))progress
                                   completion:(void (^)(ApolloGalleryDecodedImage *_Nullable decoded, NSData *_Nullable data))completion;

// The grid tier: a single downsampled still frame, cached separately from the
// full decode of the same URL. Cells use this so a reused tile never pays for
// a multi-frame GIF decode or a full-resolution bitmap it will draw at 185pt.
- (ApolloGalleryImageRequest *)loadThumbnailAtURL:(NSURL *)url
                                       completion:(void (^)(UIImage *_Nullable image))completion;

// Cache warmers. Return the request handle so look-ahead can be CANCELLED when
// the target scrolls away (grid prefetch, viewer paging); nil when the decode
// is already cached and there is nothing to do.
- (nullable ApolloGalleryImageRequest *)prefetchImageAtURL:(NSURL *)url;
- (nullable ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url;

// Drops decoded images but keeps nothing pinned; called on memory pressure.
- (void)purge;

#if APOLLO_SIM_BUILD
// Sim-only probe hook for the `gifmem` debug-tap command: runs the full-tier
// decode on raw bytes with no network or cache in the way, so the resident cost
// of one picture can be measured directly. Never compiled into device builds.
+ (nullable ApolloGalleryDecodedImage *)apollo_debugDecodeData:(NSData *)data;
#endif

@end

NS_ASSUME_NONNULL_END
