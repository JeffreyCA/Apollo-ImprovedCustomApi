// ApolloHostedVideo.h
//
// Shared resolver for external video hosts (Streamable, Redgifs) that Apollo
// plays inline but exposes to the share sheet only as a link-preview card — they
// carry no RDKVideo, so the playable mp4 AND the poster still must be resolved
// from the host's public API.
//
// Two consumers:
//   * ApolloShareAsVideo  — needs the progressive mp4 (+ audio) to export.
//   * ApolloShareAsImageGallery — needs the poster + true pixel size to replace
//     the compact link card with a full-width still (so the share card looks like
//     the post, not a junk-titled link box).
//
// Both come from the SAME single API response, so one resolver serves both. The
// completion always fires on the main queue; any field is nil/zero on failure.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, ApolloHostedVideoKind) {
    ApolloHostedVideoNone = 0,
    ApolloHostedVideoStreamable,
    ApolloHostedVideoRedgifs,
    // A sports-clip host (streamff/streamin/streamain/…) from the "Sports Clip
    // Links Play Inline" feature. Only reported while that toggle is ON, so the
    // share paths follow the same switch as inline playback: toggle off = these
    // posts are plain links again (no Share-as-Video, stock link card).
    ApolloHostedVideoSportsClip,
};

// This file is plain Objective-C (.m, C linkage) but its callers are Logos .xm
// files compiled as Objective-C++, so without extern "C" they'd reference C++
// name-mangled symbols the .m never exports (link error). Keep these in C linkage.
#ifdef __cplusplus
extern "C" {
#endif

// Classifies a post's external page URL (RDKLink.URL) into a hosted-video kind.
ApolloHostedVideoKind ApolloHostedVideoKindForURL(NSURL *url);

// Resolves a hosted video from its page URL. Streamable/Redgifs serve a single
// progressive mp4 with embedded audio, so there is never a separate audio track.
//   mp4URL    — progressive, AVFoundation-exportable mp4 (nil on failure)
//   posterURL — full-aspect poster still for the card (nil if none)
//   pixelSize — source pixel dimensions for aspect (CGSizeZero if unknown)
//   hasAudio  — whether the mp4 carries an audio track
// completion is invoked on the main queue exactly once.
void ApolloHostedVideoResolve(NSURL *pageURL,
                              void (^completion)(NSURL *mp4URL, NSURL *posterURL,
                                                 CGSize pixelSize, BOOL hasAudio));

#ifdef __cplusplus
}
#endif
