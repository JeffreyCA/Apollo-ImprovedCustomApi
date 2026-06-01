#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Suppresses the spurious "<Domain> error :( / Tap to open in browser" overlay
// shown over inline video posts in the feed when the post's static preview
// image fails to load (e.g. a RedGIFs post whose external-preview.redd.it
// poster 404s while the v.redd.it video still plays fine).
//
// -[RichMediaNode imageNode:didFailWithError:] builds a RichMediaErrorLoadingNode
// on any image-load failure without checking for a video, and layoutSpecThatFits:
// overlays it even in the video branch — so it covers the playing video. The
// comments view presents the video without that poster, so it never fires there.
//
// Fix: if the node has a video, swallow the failure (skip %orig) so no overlay
// is built. Posts with no video keep the original behavior, so genuinely broken
// image/album/link posts still surface the error.
//
// =============================================================================

// Read an ObjC object ivar by name (walks the superclass chain).
static id PreviewErrorGetIvarObject(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

%hook RichMediaNode

- (void)imageNode:(id)imageNode didFailWithError:(NSError *)error {
    // Node has a video: the failed image is just the poster, so suppress the
    // overlay and let the video play.
    id videoNode = PreviewErrorGetIvarObject(self, "videoNode");
    if (videoNode) {
        ApolloLog(@"[PreviewErrorFix] Suppressing media preview error overlay — node has a "
                  @"playable video (failed image: %@, error: %@)",
                  [imageNode class], error.localizedDescription ?: @"(none)");
        return;
    }

    %orig;
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class richMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");

    ApolloLog(@"[PreviewErrorFix] ctor: RichMediaNode=%p", (void *)richMediaNodeClass);

    if (!richMediaNodeClass) {
        ApolloLog(@"[PreviewErrorFix] ctor: RichMediaNode class not found — skipping hook");
        return;
    }

    %init(RichMediaNode = richMediaNodeClass);

    ApolloLog(@"[PreviewErrorFix] ctor: hook initialized");
}
