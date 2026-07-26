// ApolloGalleryVideoExport.h
//
// "Save Video" for Gallery View.
//
// Saving a v.redd.it clip is not just a download: Reddit serves the video and
// audio as separate DASH representations, so the progressive `fallback_url`
// everyone reaches for first is the video track ALONE. Writing that to Photos
// hands back a silent copy of something the user watched with sound.
//
// So the reddit path is: read the DASH manifest, pull the video and audio
// representations, and mux them into one mp4 with AVFoundation before saving.
// The export uses the passthrough preset — both tracks are already H.264/AAC,
// so nothing is re-encoded and nothing is lost. Self-contained sources (imgur
// mp4, Reddit's silent GIF transcodes) skip all of that and download directly.
//
// The DASH manifest parsing is shared with Share as Video rather than copied
// (see ApolloSVLowestDashURL / ApolloSVRedditAssetID in ApolloShareAsVideo.xm).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: this is defined in a .xm (ObjC++) but called from plain-ObjC .m
// files, which would otherwise look for an unmangled symbol and fail to link.
__BEGIN_DECLS

// Downloads (muxing first when the source needs it) and writes the result to
// the photo library.
//
// `progressiveURL` is a directly-downloadable mp4 — for v.redd.it that's the
// video-only fallback, used both to identify the asset and as the fallback if
// the manifest can't be read.
//
// `status` fires on the main thread with short user-facing progress text
// ("Saving…", "Merging audio…"); `completion` fires on the main thread once,
// with a message suitable for a toast.
void ApolloGallerySaveVideoToPhotos(NSURL *progressiveURL,
                                    void (^_Nullable status)(NSString *text),
                                    void (^completion)(BOOL success, NSString *message));

__END_DECLS

NS_ASSUME_NONNULL_END
