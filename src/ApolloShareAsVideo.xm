// ApolloShareAsVideo.xm
//
// "Share as Video" option for Share as Image (issue #380).
//
// Apollo's ShareAsImageViewController (_TtC6Apollo26ShareAsImageViewController)
// renders a post into a shareable card image. For a VIDEO post the card shows a
// static poster thumbnail in its media region (injected by
// ApolloShareAsImageGallery). This module adds one extra options row — "Share as
// Video" — shown only for video posts. When the toggle is ON and the user taps
// Share, instead of exporting the flat image we export an MP4: the very same card
// (title, byline, watermark — everything the user toggled) as a static backdrop,
// with the post's real video PLAYING inside the media region, sound included.
//
// How the video is built (AVFoundation, no FFmpeg — works on device and sim):
//   1. Card image  = the rendered card snapshot Apollo already shows
//      (previewSnapshotImageView.image).
//   2. Media rect  = the preview node's imageNode frame (posts) or the largest
//      inline image/video node inside baseCommentNode (comments), converted into
//      card space and normalised, so the video lands exactly over the poster/GIF.
//   3. Video asset = a progressive, exportable source:
//        * v.redd.it  -> parse DASHPlaylist.mpd for the lowest-bitrate video MP4
//          + the audio MP4 (both progressive; AVFoundation muxes them in the
//          composition). Falls back to RDKVideo.fallbackURL (video-only) if the
//          manifest can't be parsed.
//        * direct .mp4 (e.g. imgur) -> used as-is.
//        * comment inline Giphy -> its progressive giphy.mp4.
//      The playing AVPlayer is NOT used: v.redd.it plays as HLS, which
//      AVAssetExportSession cannot export. We drive everything off the post's
//      RDKLink / comment, always present whether or not the video is on screen.
//   4. Composite  = AVMutableComposition (video + audio) exported with a custom
//      AVVideoCompositing (ApolloSVCompositor): each frame is drawn with Core
//      Graphics — the card first, then the source video aspect-filled into the
//      media rect on top. A custom compositor is used instead of
//      AVVideoCompositionCoreAnimationTool, which hangs/traps in the iOS Simulator.
//      Output is a temp .mp4 handed to the share sheet in place of the image.
//
// The export is asynchronous (seconds), so when the toggle is ON we SUPPRESS
// Apollo's native (synchronous, image-only) share, show a progress overlay, build
// the video, then present our own UIActivityViewController with the file. Any
// failure falls back to Apollo's normal image share so the button never dead-ends.
//
// Coexists with ApolloShareAsImageLink's "Include Link" row: our row anchors to
// the Share button's current position and pushes the button down (after %orig) so
// it stacks below whatever other modules added. When the Include Link option is on,
// the exported video carries the post link too — added to our share sheet for
// messaging/mail (not Save Video) — exactly as Include Link does for the image.
//
// No hardcoded binary addresses: everything is ObjC-runtime ivar access (ivar
// names from class-dump headers) plus public AVFoundation/UIKit, guarded.
//
// MODULE ORDERING (Makefile ApolloReborn_FILES): this module is listed AFTER
// ApolloShareAsImageLink and BEFORE ApolloShareAsImagePreviewFix, i.e.
// Gallery -> Link -> Video -> PreviewFix. %ctor/%init() runs in that order, so this
// module's shareButtonTappedWithSender: hook installs last and is therefore the
// OUTERMOST link in the chain — it runs first and, when the video toggle is on,
// suppresses the native image share before Link's handler runs. Each module's row
// also stacks below the previous one's in its post-%orig viewDidLayoutSubviews pass.
// If you reorder these in the Makefile, re-verify the share-button chain and the row
// layout. (The Include-Link double-append guard in ApolloShareAsImageLink no longer
// depends on this order — see that file — but the layout stacking still does.)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloHostedVideo.h"

#pragma mark - Tunables

// Persisted preference: whether "Share as Video" is on. Default NO (opt-in).
static NSString *const kApolloShareVideoKey = @"ApolloShareAsImageShareVideo";
static NSString *const kApolloShareVideoTitle = @"Share as Video";

// Cap the exported clip so a 40-minute v.redd.it post doesn't produce a giant
// file / minutes-long export. Most Reddit videos are far shorter than this.
static const NSTimeInterval kApolloShareVideoMaxSeconds = 180.0;

// Native gap between the last options row and the Share button.
static const CGFloat kApolloShareVideoButtonGap = 20.0;

#pragma mark - Associated-object keys

// Repo idiom: bare `static char` whose address is the key.
static char kApolloShareVideoLabelKey;     // strong UILabel
static char kApolloShareVideoSwitchKey;    // strong UISwitch
static char kApolloShareVideoSeparatorKey; // strong UIView
static char kApolloShareVideoIsVideoKey;   // NSNumber(BOOL): post is an exportable video
static char kApolloShareVideoExportingKey; // NSNumber(BOOL): an export is in flight
static char kApolloShareVideoHUDKey;       // strong UIView (progress overlay)
static char kApolloShareVideoSessionKey;   // strong AVAssetExportSession (in flight)
static char kApolloShareVideoForceNativeKey; // NSNumber(BOOL): force the native image share once

#pragma mark - Runtime ivar helpers

static id ApolloSVIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    @try { return object_getIvar(obj, ivar); } @catch (__unused NSException *e) { return nil; }
}

static double ApolloSVIvarDouble(id obj, const char *name) {
    if (!obj || !name) return 0.0;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return 0.0;
    ptrdiff_t offset = ivar_getOffset(ivar);
    const unsigned char *base = (const unsigned char *)(__bridge const void *)obj;
    double value = 0.0;
    memcpy(&value, base + offset, sizeof(double));
    return value;
}

// Calls a 0-arg selector returning an object, guarded.
static id ApolloSVCall(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *e) { return nil; }
}

// Calls a 0-arg selector returning a double, guarded.
static double ApolloSVCallDouble(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return 0.0;
    @try { return ((double (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *e) { return 0.0; }
}

// Calls a 1-arg (object) selector returning an object, guarded.
static id ApolloSVCall1(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg); }
    @catch (__unused NSException *e) { return nil; }
}

#pragma mark - Video source model

// Returns the post's best RDKVideo (direct, then crosspost, then the readonly
// convenience), or nil. Used both to decide whether to show the toggle and to
// resolve the exportable asset.
static id ApolloSVBestVideo(id link) {
    if (!link) return nil;
    // mediaVideo  — a native v.redd.it video post.
    // crossPostVideo — a crossposted video.
    // previewVideo — Reddit's downloadable reddit_video_preview MP4 generated for
    //   EXTERNAL video link posts (YouTube/Vimeo/etc.); this is what Apollo's
    //   "Download Video…" saves, and it's hosted on v.redd.it, so it's exportable.
    // video — the readonly convenience.
    SEL order[] = { @selector(mediaVideo), @selector(crossPostVideo), @selector(previewVideo), @selector(video) };
    for (int i = 0; i < 4; i++) { id v = ApolloSVCall(link, order[i]); if (v) return v; }
    id parent = ApolloSVCall(link, @selector(crosspostParent));
    if (parent && parent != link) {
        for (int i = 0; i < 4; i++) { id v = ApolloSVCall(parent, order[i]); if (v) return v; }
    }
    return nil;
}

static BOOL ApolloSVHostContains(NSURL *url, NSString *needle) {
    return [url isKindOfClass:[NSURL class]] && [(url.host ?: @"") rangeOfString:needle].location != NSNotFound;
}

static BOOL ApolloSVIsMP4(NSURL *url) {
    return [url isKindOfClass:[NSURL class]] &&
           [[(url.path ?: @"") pathExtension] caseInsensitiveCompare:@"mp4"] == NSOrderedSame;
}

// Rewrites a GIF-ish media URL to a progressive .mp4 AVFoundation can export, or
// returns nil if there's no known mp4 form (i.redd.it .gif / Redgifs HLS / etc.).
// Giphy and imgur both serve an .mp4 at the same path as the .gif.
static NSURL *ApolloSVToExportableMP4(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (ApolloSVIsMP4(url)) return url;
    NSString *host = url.host ?: @"";
    NSString *ext = url.pathExtension.lowercaseString;
    NSString *s = url.absoluteString;
    if (([host containsString:@"giphy.com"] || [host containsString:@"imgur.com"]) &&
        ([ext isEqualToString:@"gif"] || [ext isEqualToString:@"gifv"])) {
        NSString *base = [s substringToIndex:s.length - ext.length - 1]; // drop ".gif"/".gifv"
        return [NSURL URLWithString:[base stringByAppendingString:@".mp4"]];
    }
    return nil;
}

#pragma mark - External hosted video (Streamable / Redgifs)

// Some external video posts (Streamable, Redgifs) carry NO RDKVideo — Apollo plays
// them inline by resolving the host's own API at runtime, but exposes them to the
// share sheet only as a link card whose external page URL sits on -[RDKLink URL].
// Apollo's resolved URL is never written back to the link and its resolvers are
// pure-Swift (no @objc entry point), so we resolve the progressive mp4 ourselves
// from the host's public API at export time. Host classification + resolution live
// in the shared ApolloHostedVideo helper (also used by ApolloShareAsImageGallery to
// replace the link card with the video poster). Both hosts serve a single combined
// mp4 with embedded audio, so no separate audio track is needed.

// SYNCHRONOUS feasibility check (decides whether the toggle is shown). True when
// the post has a video we can produce a progressive, exportable file for:
//   * a v.redd.it video (we'll resolve its DASH MP4 + audio at export time), or
//   * a direct .mp4 URL, or
//   * a Streamable / Redgifs link post (resolved via the host API at export time).
static BOOL ApolloSVPostIsExportableVideo(id link) {
    // Preferred fast paths: a real RDKVideo we can export with no extra network —
    // v.redd.it (DASH) or a direct .mp4. Reddit also synthesizes a v.redd.it
    // previewVideo for some external link posts, which is covered here too.
    id video = ApolloSVBestVideo(link);
    if (video) {
        NSURL *url   = (NSURL *)ApolloSVCall(video, @selector(URL));
        NSURL *fb    = (NSURL *)ApolloSVCall(video, @selector(fallbackURL));
        NSURL *small = (NSURL *)ApolloSVCall(video, @selector(smallerURL));
        if (ApolloSVHostContains(url, @"v.redd.it") || ApolloSVHostContains(fb, @"v.redd.it")) return YES;
        if (ApolloSVIsMP4(url) || ApolloSVIsMP4(fb) || ApolloSVIsMP4(small)) return YES;
    }
    // External hosts Apollo plays inline but exposes only as a link card (no
    // RDKVideo): Streamable / Redgifs. Their progressive mp4 is resolved from the
    // link's page URL at export time, so offer the toggle here.
    NSURL *pageURL = (NSURL *)ApolloSVCall(link, @selector(URL));
    if (ApolloHostedVideoKindForURL(pageURL) != ApolloHostedVideoNone) return YES;
    return NO;
}

// SYNCHRONOUS feasibility for a COMMENT share: the comment carries an inline GIF
// we can export. v1 covers Giphy (the comment GIF picker's source) — it has a
// progressive .mp4 form. Detection only needs the comment object, not layout.
static BOOL ApolloSVCommentExportable(id comment) {
    if (!comment) return NO;
    NSDictionary *giphy = (NSDictionary *)ApolloSVCall(comment, @selector(inlineGiphyIDsToURLs));
    if ([giphy isKindOfClass:[NSDictionary class]] && giphy.count > 0) return YES;
    return NO;
}

// First Giphy id on the comment, and its progressive .mp4. Apollo's resolver gives
// an mp4-or-gif URL; we coerce to mp4 (same path) and fall back to the canonical
// media.giphy.com path built from the id.
static NSURL *ApolloSVCommentGiphyMP4(id comment) {
    if (!comment) return nil;
    NSDictionary *giphy = (NSDictionary *)ApolloSVCall(comment, @selector(inlineGiphyIDsToURLs));
    if (![giphy isKindOfClass:[NSDictionary class]] || giphy.count == 0) return nil;
    NSString *gid = nil;
    for (id k in giphy) { if ([k isKindOfClass:[NSString class]] && [k length]) { gid = k; break; } }
    if (!gid) return nil;
    NSString *bareID = [gid hasPrefix:@"giphy|"] ? [gid substringFromIndex:6] : gid;

    id resolved = ApolloSVCall1(comment, @selector(mp4OrGIFURLForInlineGiphyWithID:), gid);
    NSURL *url = [resolved isKindOfClass:[NSURL class]] ? (NSURL *)resolved
               : ([resolved isKindOfClass:[NSString class]] ? [NSURL URLWithString:(NSString *)resolved] : nil);
    NSURL *mp4 = ApolloSVToExportableMP4(url);
    if (mp4) return mp4;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.mp4", bareID]];
}

// Extracts the v.redd.it asset id (first path component) from a v.redd.it URL.
static NSString *ApolloSVRedditAssetID(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (!ApolloSVHostContains(url, @"v.redd.it")) return nil;
    for (NSString *comp in url.pathComponents) {
        if (comp.length > 0 && ![comp isEqualToString:@"/"]) return comp;
    }
    return nil;
}

// Finds the lowest-bitrate <BaseURL>…</BaseURL> MP4 for the given DASH content
// type ("video" or "audio"). Reddit orders Representations ascending by bitrate,
// so the first match after the matching AdaptationSet is the smallest. Mirrors
// ApolloInlineImages' poster parser, generalised to either track.
static NSURL *ApolloSVLowestDashURL(NSData *mpdData, NSURL *mpdURL, NSString *contentType) {
    if (mpdData.length == 0 || !mpdURL) return nil;
    NSString *xml = [[NSString alloc] initWithData:mpdData encoding:NSUTF8StringEncoding];
    if (xml.length == 0) return nil;

    NSRange searchRange = NSMakeRange(0, xml.length);
    NSString *marker = [NSString stringWithFormat:@"contentType=\"%@\"", contentType];
    NSRange set = [xml rangeOfString:marker];
    if (set.location != NSNotFound) {
        // Bound the search to this AdaptationSet so we don't pick the other track's
        // BaseURL: stop at the next "<AdaptationSet" after the marker.
        NSUInteger start = set.location;
        NSRange rest = NSMakeRange(start, xml.length - start);
        NSRange next = [xml rangeOfString:@"<AdaptationSet"
                                  options:0
                                    range:NSMakeRange(start + marker.length, xml.length - start - marker.length)];
        NSUInteger end = (next.location != NSNotFound) ? next.location : xml.length;
        searchRange = NSMakeRange(start, end - start);
        (void)rest;
    } else if (![contentType isEqualToString:@"video"]) {
        // No audio AdaptationSet -> no audio track.
        return nil;
    }

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<BaseURL>([^<]+\\.mp4)</BaseURL>" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:searchRange];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *relative = [xml substringWithRange:[m rangeAtIndex:1]];
    return [NSURL URLWithString:relative relativeToURL:mpdURL].absoluteURL;
}

// Resolves the progressive video URL (+ optional audio URL) for the post. Async
// because the v.redd.it path fetches the DASH manifest. Calls back on the main
// queue; videoURL is nil if nothing exportable could be resolved.
static void ApolloSVResolveSources(id link, void (^completion)(NSURL *videoURL, NSURL *audioURL, CGSize naturalSize)) {
    void (^done)(NSURL *, NSURL *, CGSize) = ^(NSURL *v, NSURL *a, CGSize s) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(v, a, s); });
    };

    NSURL *pageURL = (NSURL *)ApolloSVCall(link, @selector(URL));
    id video = ApolloSVBestVideo(link);
    NSURL *url   = video ? (NSURL *)ApolloSVCall(video, @selector(URL)) : nil;
    NSURL *fb    = video ? (NSURL *)ApolloSVCall(video, @selector(fallbackURL)) : nil;
    NSURL *small = video ? (NSURL *)ApolloSVCall(video, @selector(smallerURL)) : nil;
    double w = video ? ApolloSVCallDouble(video, @selector(width))  : 0.0;
    double h = video ? ApolloSVCallDouble(video, @selector(height)) : 0.0;
    CGSize natural = (w > 0 && h > 0) ? CGSizeMake(w, h) : CGSizeZero;

    // Resolves from the post's RDKVideo: a v.redd.it DASH stream (split video+audio)
    // or a direct progressive .mp4. Used for native videos, and as the fallback when
    // a hosted-source resolve fails.
    void (^resolveFromRDKVideo)(void) = ^{
        if (!video) { done(nil, nil, natural); return; }
        NSString *assetID = ApolloSVRedditAssetID(url) ?: ApolloSVRedditAssetID(fb);
        if (assetID.length > 0) {
            NSURL *mpd = [NSURL URLWithString:[NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd", assetID]];
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:mpd
                                                              cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                          timeoutInterval:10.0];
            ApolloLog(@"[ShareVideo] resolving v.redd.it asset=%@", assetID);
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)response).statusCode : 0;
                NSURL *videoURL = nil, *audioURL = nil;
                if (!error && status >= 200 && status < 300 && data.length) {
                    videoURL = ApolloSVLowestDashURL(data, mpd, @"video");
                    audioURL = ApolloSVLowestDashURL(data, mpd, @"audio");
                }
                if (!videoURL) {
                    // Manifest unavailable/unparseable: fall back to the API's
                    // progressive fallback MP4 (video-only, no audio).
                    videoURL = ApolloSVIsMP4(fb) ? fb : (ApolloSVIsMP4(url) ? url : nil);
                    audioURL = nil;
                }
                ApolloLog(@"[ShareVideo] v.redd.it resolved video=%@ audio=%@",
                          videoURL ? @"yes" : @"no", audioURL ? @"yes" : @"no");
                done(videoURL, audioURL, natural);
            }];
            [task resume];
            return;
        }
        // Direct progressive MP4 (e.g. imgur). No separate audio track to fetch; if
        // the file itself carries audio the composition picks it up from this asset.
        NSURL *direct = ApolloSVIsMP4(url) ? url : (ApolloSVIsMP4(fb) ? fb : (ApolloSVIsMP4(small) ? small : nil));
        if (direct) {
            ApolloLog(@"[ShareVideo] direct mp4 resolved=yes");
            done(direct, nil, natural);
            return;
        }
        ApolloLog(@"[ShareVideo] no exportable RDKVideo source");
        done(nil, nil, natural);
    };

    // Prefer the host's own mp4 for Streamable/Redgifs posts: it carries the
    // original audio + full quality, whereas Reddit's reddit_video_preview (which
    // ApolloSVBestVideo picks for these external links) is SILENT and re-encoded.
    // Fall back to the RDKVideo path if the host resolve fails.
    if (ApolloHostedVideoKindForURL(pageURL) != ApolloHostedVideoNone) {
        ApolloLog(@"[ShareVideo] hosted post — preferring host mp4 over reddit preview");
        ApolloHostedVideoResolve(pageURL, ^(NSURL *mp4, __unused NSURL *poster,
                                            CGSize pixelSize, __unused BOOL hasAudio) {
            if (mp4) {
                CGSize sz = (natural.width > 0 && natural.height > 0) ? natural : pixelSize;
                done(mp4, nil, sz);
            } else {
                ApolloLog(@"[ShareVideo] host resolve failed — falling back to RDKVideo");
                resolveFromRDKVideo();
            }
        });
        return;
    }
    resolveFromRDKVideo();
}

#pragma mark - Card image + media rect

// ASDisplayNode geometry accessors via objc_msgSend (ASDisplayNode isn't headered
// here). bounds is a CGRect property; convertRect:toNode: maps into card space.
static CGRect ApolloSVNodeBounds(id node) {
    if (!node || ![node respondsToSelector:@selector(bounds)]) return CGRectZero;
    @try { return ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(bounds)); }
    @catch (__unused NSException *e) { return CGRectZero; }
}

static CGRect ApolloSVConvertRectToNode(id from, CGRect rect, id toNode) {
    if (!from || !toNode || ![from respondsToSelector:@selector(convertRect:toNode:)]) return CGRectZero;
    @try { return ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(from, @selector(convertRect:toNode:), rect, toNode); }
    @catch (__unused NSException *e) { return CGRectZero; }
}

// The card image Apollo already rendered for the preview. Points; .scale is the
// screen scale (pixels = size * scale).
static UIImage *ApolloSVCardImage(id vc) {
    UIImageView *iv = (UIImageView *)ApolloSVIvarObject(vc, "previewSnapshotImageView");
    if ([iv isKindOfClass:[UIImageView class]] && [iv.image isKindOfClass:[UIImage class]]) return iv.image;
    return nil;
}

// Recursively collects image/video display nodes under `node` (matched by class
// name, since the concrete Texture classes aren't headered here).
static void ApolloSVCollectMediaNodes(id node, int depth, NSMutableArray *out) {
    if (!node || depth > 8) return;
    NSArray *subs = nil;
    if ([node respondsToSelector:@selector(subnodes)]) {
        @try { subs = ((id (*)(id, SEL))objc_msgSend)(node, @selector(subnodes)); }
        @catch (__unused NSException *e) {}
    }
    if (![subs isKindOfClass:[NSArray class]]) return;
    for (id sub in subs) {
        const char *cn = class_getName(object_getClass(sub));
        NSString *cls = cn ? @(cn) : @"";
        if ([cls containsString:@"ImageNode"] || [cls containsString:@"VideoNode"]) [out addObject:sub];
        ApolloSVCollectMediaNodes(sub, depth + 1, out);
    }
}

// The largest-area image/video node under `root` — for a comment cell this is the
// inline GIF, not the small author avatar.
static id ApolloSVLargestMediaNode(id root) {
    NSMutableArray *nodes = [NSMutableArray array];
    ApolloSVCollectMediaNodes(root, 0, nodes);
    id best = nil; CGFloat bestArea = 0;
    for (id n in nodes) {
        CGRect b = ApolloSVNodeBounds(n);
        CGFloat area = b.size.width * b.size.height;
        if (area > bestArea) { bestArea = area; best = n; }
    }
    return bestArea > 400 ? best : nil; // ignore avatars / tiny nodes
}

// The media region as a fraction (0..1) of the card. For a post it's the preview's
// imageNode; for a comment it's the largest media node inside baseCommentNode.
static BOOL ApolloSVMediaRectNormalized(id vc, CGRect *outNorm) {
    id previewNode = ApolloSVIvarObject(vc, "previewNode");
    if (!previewNode) return NO;

    id mediaNode = nil;
    if (ApolloSVIvarObject(vc, "comment") != nil) {
        id baseCommentNode = ApolloSVIvarObject(previewNode, "baseCommentNode");
        mediaNode = ApolloSVLargestMediaNode(baseCommentNode ?: previewNode);
    } else {
        // Native media posts expose the preview's imageNode directly. External
        // video link posts (Streamable / Redgifs) render a link-preview card whose
        // thumbnail isn't `imageNode`, so target the largest image/video node in
        // the card — that thumbnail is what we composite the video over. Each path
        // cross-falls-back to the other for robustness.
        NSURL *pageURL = (NSURL *)ApolloSVCall(ApolloSVIvarObject(vc, "link"), @selector(URL));
        if (ApolloHostedVideoKindForURL(pageURL) != ApolloHostedVideoNone) {
            mediaNode = ApolloSVLargestMediaNode(previewNode) ?: ApolloSVIvarObject(previewNode, "imageNode");
            ApolloLog(@"[ShareVideo] hosted-link post media node=%@", mediaNode ? @"largest" : @"none");
        } else {
            mediaNode = ApolloSVIvarObject(previewNode, "imageNode") ?: ApolloSVLargestMediaNode(previewNode);
        }
    }
    if (!mediaNode) return NO;

    CGRect cardBounds = ApolloSVNodeBounds(previewNode);
    CGRect mediaBounds = ApolloSVNodeBounds(mediaNode);
    if (cardBounds.size.width <= 1 || cardBounds.size.height <= 1) return NO;
    if (mediaBounds.size.width <= 1 || mediaBounds.size.height <= 1) return NO;

    CGRect mediaInCard = ApolloSVConvertRectToNode(mediaNode, mediaBounds, previewNode);
    if (mediaInCard.size.width <= 1 || mediaInCard.size.height <= 1) return NO;

    CGRect norm = CGRectMake(mediaInCard.origin.x / cardBounds.size.width,
                             mediaInCard.origin.y / cardBounds.size.height,
                             mediaInCard.size.width / cardBounds.size.width,
                             mediaInCard.size.height / cardBounds.size.height);
    // Sanity-clamp to the card.
    if (norm.origin.x < -0.01 || norm.origin.y < -0.01 ||
        CGRectGetMaxX(norm) > 1.01 || CGRectGetMaxY(norm) > 1.01) return NO;
    *outNorm = norm;
    return YES;
}

#pragma mark - Custom video compositor (Core Graphics — works in sim AND on device)

// AVVideoCompositionCoreAnimationTool hangs/SIGTRAPs mid-export in the iOS
// Simulator (it depends on a Core Animation render-server path the sim doesn't
// fully support). So we composite every frame ourselves with Core Graphics: draw
// the static card, then the live video frame on top, clipped to the media rect
// (aspect-fill, so it covers the poster exactly). Plain CG works everywhere and
// removes the CALayer coordinate-flip guesswork. AVAssetExportSession still muxes
// the audio track for us — only the video is custom-composited.
//
// Per-export draw parameters travel WITH the composition, as a custom
// AVVideoCompositionInstruction (the documented pattern — cf. Apple's AVCustomEdit),
// rather than through file statics. The compositor reads them back per frame from
// request.videoCompositionInstruction, so two exports running at once (e.g. two
// Share-as-Image sheets in iPad multi-window) can never clobber each other's card,
// media rect, or transform. Combined with the unique per-export temp filename in
// ApolloSVExport, nothing about the export relies on only one running at a time.
@interface ApolloSVInstruction : NSObject <AVVideoCompositionInstruction>
// AVVideoCompositionInstruction protocol requirements (declared readwrite here):
@property (nonatomic, assign) CMTimeRange timeRange;
@property (nonatomic, assign) BOOL enablePostProcessing;
@property (nonatomic, assign) BOOL containsTweening;
@property (nonatomic, strong) NSArray<NSValue *> *requiredSourceTrackIDs;
@property (nonatomic, assign) CMPersistentTrackID passthroughTrackID;
// Our per-frame draw inputs:
@property (nonatomic, assign) CGImageRef cardImage;             // retained (see setter)
@property (nonatomic, assign) CGRect mediaRect;                 // pixels, UIKit top-left
@property (nonatomic, assign) CGAffineTransform videoPreferred; // source preferredTransform
@property (nonatomic, assign) int32_t videoTrackID;
@end

@implementation ApolloSVInstruction
// CGImageRef isn't ARC-managed; retain on set, release the old one + on dealloc, so
// the card image lives exactly as long as the instruction (i.e. the export).
- (void)setCardImage:(CGImageRef)cardImage {
    if (cardImage == _cardImage) return;
    if (cardImage) CGImageRetain(cardImage);
    if (_cardImage) CGImageRelease(_cardImage);
    _cardImage = cardImage;
}
- (void)dealloc {
    if (_cardImage) CGImageRelease(_cardImage);
}
@end

// CVPixelBuffer (BGRA) -> UIImage, mapping the source preferredTransform to a
// UIImageOrientation so portrait clips recorded as rotated landscape draw upright.
static UIImage *ApolloSVImageFromBuffer(CVPixelBufferRef buf, CGAffineTransform pref) {
    if (!buf) return nil;
    CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buf), w, h, 8,
        CVPixelBufferGetBytesPerRow(buf), cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef cg = bctx ? CGBitmapContextCreateImage(bctx) : NULL;
    if (bctx) CGContextRelease(bctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    if (!cg) return nil;
    // Map the source preferredTransform to a UIImageOrientation. All eight
    // orientations are covered (the four mirrored ones included) so a flipped clip
    // would still draw upright; real v.redd.it/Giphy sources won't be mirrored, but
    // this is exhaustive rather than falling through to Up.
    UIImageOrientation orient = UIImageOrientationUp;
    CGFloat a = pref.a, b = pref.b, c = pref.c, d = pref.d;
    if (a == 0 && b == 1 && c == -1 && d == 0)       orient = UIImageOrientationRight;        // 90° CW
    else if (a == 0 && b == -1 && c == 1 && d == 0)  orient = UIImageOrientationLeft;         // 90° CCW
    else if (a == -1 && b == 0 && c == 0 && d == -1) orient = UIImageOrientationDown;         // 180°
    else if (a == -1 && b == 0 && c == 0 && d == 1)  orient = UIImageOrientationUpMirrored;   // horizontal flip
    else if (a == 1 && b == 0 && c == 0 && d == -1)  orient = UIImageOrientationDownMirrored; // vertical flip
    else if (a == 0 && b == -1 && c == -1 && d == 0) orient = UIImageOrientationLeftMirrored;
    else if (a == 0 && b == 1 && c == 1 && d == 0)   orient = UIImageOrientationRightMirrored;
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:orient];
    CGImageRelease(cg);
    return img;
}

@interface ApolloSVCompositor : NSObject <AVVideoCompositing>
@end

@implementation ApolloSVCompositor

- (NSDictionary *)sourcePixelBufferAttributes {
    return @{ (id)kCVPixelBufferPixelFormatTypeKey: @[@(kCVPixelFormatType_32BGRA)] };
}
- (NSDictionary *)requiredPixelBufferAttributesForRenderContext {
    return @{ (id)kCVPixelBufferPixelFormatTypeKey: @[@(kCVPixelFormatType_32BGRA)] };
}
- (void)renderContextChanged:(AVVideoCompositionRenderContext *)newRenderContext {}

- (void)startVideoCompositionRequest:(AVAsynchronousVideoCompositionRequest *)request {
    @autoreleasepool {
        // Per-export draw parameters ride on the instruction (no shared file state).
        ApolloSVInstruction *inst = nil;
        id rawInst = request.videoCompositionInstruction;
        if ([rawInst isKindOfClass:[ApolloSVInstruction class]]) inst = (ApolloSVInstruction *)rawInst;
        if (!inst) {
            // Should never happen — only our instruction is installed on the video
            // composition. Fail loudly rather than composing an all-black frame, so an
            // unexpected instruction type surfaces as an export error (which falls back
            // to the native image share) instead of a silently-broken black video.
            [request finishWithError:[NSError errorWithDomain:@"ApolloShareVideo" code:11 userInfo:nil]];
            return;
        }

        CVPixelBufferRef dst = [request.renderContext newPixelBuffer];
        if (!dst) {
            [request finishWithError:[NSError errorWithDomain:@"ApolloShareVideo" code:10 userInfo:nil]];
            return;
        }
        CVPixelBufferRef src = [request sourceFrameByTrackID:inst.videoTrackID];
        CGImageRef cardCG = inst.cardImage;
        CGRect mediaRect = inst.mediaRect;
        CGAffineTransform pref = inst.videoPreferred;

        CVPixelBufferLockBaseAddress(dst, 0);
        size_t w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(dst), w, h, 8,
            CVPixelBufferGetBytesPerRow(dst), cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

        if (ctx) {
            // Draw in UIKit (top-left) coordinates.
            CGContextTranslateCTM(ctx, 0, h);
            CGContextScaleCTM(ctx, 1, -1);
            UIGraphicsPushContext(ctx);

            [[UIColor blackColor] setFill];
            UIRectFill(CGRectMake(0, 0, w, h));

            // The full card (header, title, poster, watermark) — full frame.
            if (cardCG) {
                [[UIImage imageWithCGImage:cardCG] drawInRect:CGRectMake(0, 0, w, h)];
            }
            // The live video frame, aspect-filled into the media rect (covers poster).
            UIImage *frame = ApolloSVImageFromBuffer(src, pref);
            if (frame && frame.size.width > 0 && frame.size.height > 0) {
                CGContextSaveGState(ctx);
                CGContextClipToRect(ctx, mediaRect);
                CGFloat sc = MAX(mediaRect.size.width / frame.size.width,
                                 mediaRect.size.height / frame.size.height);
                CGSize ds = CGSizeMake(frame.size.width * sc, frame.size.height * sc);
                CGRect dr = CGRectMake(CGRectGetMidX(mediaRect) - ds.width / 2.0,
                                       CGRectGetMidY(mediaRect) - ds.height / 2.0,
                                       ds.width, ds.height);
                [frame drawInRect:dr];
                CGContextRestoreGState(ctx);
            }

            UIGraphicsPopContext();
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
        CVPixelBufferUnlockBaseAddress(dst, 0);

        [request finishWithComposedVideoFrame:dst];
        CVPixelBufferRelease(dst);
    }
}

@end

#pragma mark - Composition / export

// Even-rounds a dimension (H.264 requires even width/height).
static CGFloat ApolloSVEven(CGFloat v) { long n = lround(v); if (n & 1) n += 1; return (CGFloat)n; }

// Builds and exports the composited MP4. Calls progress(0..1) on the main queue
// during export and completion(outURL,error) on the main queue when finished.
// Keeps strong refs to its CALayers/session on `vc` so nothing is reclaimed
// mid-export.
// Composites the live video over the card and exports an mp4. `videoURL` should be
// a LOCAL file (materialized by ApolloSVExport) so AVFoundation reads the full
// track list. `tempVideoFile`, if non-nil, is that downloaded temp file and is
// deleted once the export finishes or fails.
static void ApolloSVComposeAndExport(id vc, UIImage *card, CGRect mediaNorm,
                                     NSURL *videoURL, NSURL *audioURL, NSURL *tempVideoFile,
                                     void (^progress)(float p),
                                     void (^completion)(NSURL *outURL, NSError *error)) {
    void (^cleanupTemp)(void) = ^{
        if (tempVideoFile) [[NSFileManager defaultManager] removeItemAtURL:tempVideoFile error:nil];
    };
    void (^fail)(NSString *) = ^(NSString *why) {
        cleanupTemp();
        ApolloLog(@"[ShareVideo] export FAIL: %@", why);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"ApolloShareVideo" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: why ?: @"unknown"}]);
        });
    };

    if (![card isKindOfClass:[UIImage class]] || !videoURL) { fail(@"missing card or video url"); return; }

    // Output canvas = the card rasterised to pixels, but capped to ~720px wide so
    // shared files stay reasonable (HighestQuality at the device's full 3× scale
    // produced ~68 MB for ~55s). Text stays crisp at this width.
    CGFloat baseScale = card.scale > 0 ? card.scale : 2.0;
    CGFloat scale = MIN(baseScale, 720.0 / MAX(card.size.width, 1.0));
    if (scale < 1.0) scale = 1.0;
    CGSize renderSize = CGSizeMake(ApolloSVEven(card.size.width * scale),
                                   ApolloSVEven(card.size.height * scale));
    // Media rect in pixels (UIKit top-left) where the video is composited.
    CGRect mediaPx = CGRectMake(mediaNorm.origin.x * renderSize.width,
                                mediaNorm.origin.y * renderSize.height,
                                mediaNorm.size.width * renderSize.width,
                                mediaNorm.size.height * renderSize.height);

    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVURLAsset *audioAsset = audioURL ? [AVURLAsset URLAssetWithURL:audioURL
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}] : nil;

    NSMutableArray *keysToLoad = [NSMutableArray arrayWithObject:videoAsset];
    if (audioAsset) [keysToLoad addObject:audioAsset];

    dispatch_group_t group = dispatch_group_create();
    for (AVURLAsset *a in keysToLoad) {
        dispatch_group_enter(group);
        [a loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        if ([videoAsset statusOfValueForKey:@"tracks" error:&err] != AVKeyValueStatusLoaded) {
            fail([NSString stringWithFormat:@"video tracks not loaded: %@", err.localizedDescription]); return;
        }
        AVAssetTrack *srcVideo = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!srcVideo) { fail(@"no video track"); return; }

        // Audio: prefer the separate audio asset (v.redd.it), else the video file's
        // own audio (direct mp4).
        AVAssetTrack *srcAudio = nil;
        AVURLAsset *audioHost = nil;
        if (audioAsset && [audioAsset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
            srcAudio = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            audioHost = audioAsset;
        }
        if (!srcAudio) {
            srcAudio = [[videoAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            audioHost = videoAsset;
        }

        // Clip duration: shortest available track, capped.
        CMTime vDur = videoAsset.duration;
        CMTime dur = vDur;
        if (srcAudio && CMTIME_IS_NUMERIC(audioHost.duration)) dur = CMTimeMinimum(dur, audioHost.duration);
        CMTime cap = CMTimeMakeWithSeconds(kApolloShareVideoMaxSeconds, 600);
        if (CMTIME_COMPARE_INLINE(dur, >, cap)) dur = cap;
        if (!CMTIME_IS_NUMERIC(dur) || CMTimeGetSeconds(dur) <= 0) { fail(@"bad duration"); return; }
        CMTimeRange range = CMTimeRangeMake(kCMTimeZero, dur);

        AVMutableComposition *comp = [AVMutableComposition composition];
        AVMutableCompositionTrack *vTrack = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                             preferredTrackID:kCMPersistentTrackID_Invalid];
        NSError *insErr = nil;
        if (![vTrack insertTimeRange:range ofTrack:srcVideo atTime:kCMTimeZero error:&insErr]) {
            fail([NSString stringWithFormat:@"video insert: %@", insErr.localizedDescription]); return;
        }
        if (srcAudio) {
            AVMutableCompositionTrack *aTrack = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                 preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime aDur = CMTimeMinimum(range.duration, audioHost.duration);
            [aTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, aDur) ofTrack:srcAudio atTime:kCMTimeZero error:nil];
        }

        // Video composition driven by our custom Core Graphics compositor. The
        // per-frame draw inputs (card, media rect, preferredTransform, track id) are
        // carried ON the instruction (ApolloSVInstruction) rather than via shared
        // statics, so concurrent exports can't clobber each other.
        ApolloSVInstruction *inst = [[ApolloSVInstruction alloc] init];
        inst.timeRange = range;
        inst.enablePostProcessing = NO;
        inst.containsTweening = NO;
        inst.passthroughTrackID = kCMPersistentTrackID_Invalid; // never pass through — always composite
        inst.requiredSourceTrackIDs = @[@(vTrack.trackID)];
        inst.cardImage = card.CGImage;
        inst.mediaRect = mediaPx;
        inst.videoPreferred = srcVideo.preferredTransform;
        inst.videoTrackID = vTrack.trackID;

        AVMutableVideoComposition *vc2 = [AVMutableVideoComposition videoComposition];
        vc2.renderSize = renderSize;
        float fps = srcVideo.nominalFrameRate;
        if (fps < 1 || fps > 60 || !isfinite(fps)) fps = 30.0;
        vc2.frameDuration = CMTimeMake(1, (int32_t)lround(fps));
        vc2.instructions = @[inst];
        vc2.customVideoCompositorClass = [ApolloSVCompositor class];

        // Unique temp filename per export (don't reuse a fixed "ApolloPost.mp4"), so
        // two concurrent exports can't overwrite each other's output mid-flight.
        NSString *outName = [NSString stringWithFormat:@"ApolloShareVideo-%@.mp4",
                             [[NSProcessInfo processInfo] globallyUniqueString]];
        NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:outName];
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];

        AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:comp
                                                                   presetName:AVAssetExportPresetHighestQuality];
        if (!ex) { fail(@"could not create export session"); return; }
        ex.videoComposition = vc2;
        ex.outputURL = outURL;
        ex.outputFileType = AVFileTypeMPEG4;
        ex.shouldOptimizeForNetworkUse = YES;

        // Keep the session alive on the VC for the export's lifetime.
        dispatch_async(dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(vc, &kApolloShareVideoSessionKey, ex, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });

        // Progress polling.
        __block BOOL finished = NO;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (finished) return;
            float p = ex.progress;
            dispatch_async(dispatch_get_main_queue(), ^{ if (progress) progress(p); });
        });
        dispatch_resume(timer);

        ApolloLog(@"[ShareVideo] export start render=%.0fx%.0f media=%@ dur=%.1fs audio=%d",
                  renderSize.width, renderSize.height, NSStringFromCGRect(mediaPx),
                  CMTimeGetSeconds(range.duration), srcAudio != nil);

        [ex exportAsynchronouslyWithCompletionHandler:^{
            finished = YES;
            dispatch_source_cancel(timer);
            AVAssetExportSessionStatus st = ex.status;
            // No shared compositor state to tear down — the instruction (and its
            // retained card image) is released with the composition after export.
            dispatch_async(dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(vc, &kApolloShareVideoSessionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                cleanupTemp(); // the downloaded source is no longer needed
                if (st == AVAssetExportSessionStatusCompleted) {
                    ApolloLog(@"[ShareVideo] export OK -> %@", outPath);
                    completion(outURL, nil);
                } else {
                    NSError *e = ex.error;
                    ApolloLog(@"[ShareVideo] export status=%ld err=%@", (long)st, e.localizedDescription);
                    completion(nil, e ?: [NSError errorWithDomain:@"ApolloShareVideo" code:(NSInteger)st userInfo:nil]);
                }
            });
        }];
    });
}

#pragma mark - Source materialization + export entry

// Downloads a remote http(s) URL to a local temp .mp4, returning its file URL (nil
// on failure). AVFoundation needs a LOCAL file to reliably enumerate every track:
// streaming a non-fast-start mp4 (e.g. Redgifs' CDN files) can leave the embedded
// audio track undiscovered, exporting a silent clip. A local copy also dodges
// signed-URL expiry mid-export. A browser User-Agent is sent so CDN-gating hosts
// (Redgifs) still serve it. cb runs on the URLSession queue.
static void ApolloSVDownloadToTemp(NSURL *url, void (^cb)(NSURL *localURL)) {
    if (![url isKindOfClass:[NSURL class]]) { cb(nil); return; }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) { cb(nil); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:60.0];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        forHTTPHeaderField:@"User-Agent"];
    ApolloLog(@"[ShareVideo] materializing source to temp…");
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL *tmp, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || !tmp || (status && (status < 200 || status >= 300))) {
            ApolloLog(@"[ShareVideo] source download failed (http %ld: %@) — falling back to streaming",
                      (long)status, error.localizedDescription);
            cb(nil); return;
        }
        NSURL *dest = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"ApolloShareVideoSrc-%@.mp4",
                                         [[NSUUID UUID] UUIDString]]];
        [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
        NSError *moveErr = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:tmp toURL:dest error:&moveErr]) {
            ApolloLog(@"[ShareVideo] temp move failed: %@ — falling back to streaming", moveErr.localizedDescription);
            cb(nil); return;
        }
        cb(dest);
    }];
    [task resume];
}

// Export entry. For the COMBINED-mp4 case (audioURL == nil: Streamable / Redgifs /
// direct mp4) the embedded audio lives in the video file itself, so the file is
// first materialized to local temp — otherwise non-fast-start sources export
// silent. v.redd.it (separate audio track, audioURL != nil) is the common path and
// already streams reliably, so it is left untouched. Falls back to streaming if the
// download fails.
static void ApolloSVExport(id vc, UIImage *card, CGRect mediaNorm,
                           NSURL *videoURL, NSURL *audioURL,
                           void (^progress)(float p),
                           void (^completion)(NSURL *outURL, NSError *error)) {
    if (![card isKindOfClass:[UIImage class]] || !videoURL) {
        ApolloLog(@"[ShareVideo] export FAIL: missing card or video url");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"ApolloShareVideo" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"missing card or video url"}]);
        });
        return;
    }
    ApolloLog(@"[ShareVideo] export entry: audioURL=%@", audioURL ? @"present" : @"nil");
    if (audioURL != nil) { // v.redd.it: separate audio track streams fine
        ApolloSVComposeAndExport(vc, card, mediaNorm, videoURL, audioURL, nil, progress, completion);
        return;
    }
    ApolloSVDownloadToTemp(videoURL, ^(NSURL *localVideoURL) {
        NSURL *useVideoURL = localVideoURL ?: videoURL;
        NSURL *tempVideoFile = (localVideoURL && localVideoURL.isFileURL) ? localVideoURL : nil;
        ApolloSVComposeAndExport(vc, card, mediaNorm, useVideoURL, audioURL, tempVideoFile, progress, completion);
    });
}

#pragma mark - Progress HUD

// Tears a HUD overlay off the screen directly, by view reference — no VC needed.
// This is what makes the HUD impossible to orphan: the export blocks capture the
// overlay view strongly, so even if the VC (and its associated-object handle) is
// gone, the overlay can still be removed. Idempotent and main-thread-safe.
static void ApolloSVRemoveHUDView(UIView *hud) {
    if (![hud isKindOfClass:[UIView class]]) return;
    dispatch_block_t teardown = ^{
        [UIView animateWithDuration:0.2 animations:^{ hud.alpha = 0; }
                         completion:^(__unused BOOL done) { [hud removeFromSuperview]; }];
    };
    if ([NSThread isMainThread]) teardown();
    else dispatch_async(dispatch_get_main_queue(), teardown);
}

static void ApolloSVHideHUD(id vc) {
    ApolloSVRemoveHUDView((UIView *)objc_getAssociatedObject(vc, &kApolloShareVideoHUDKey));
    objc_setAssociatedObject(vc, &kApolloShareVideoHUDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Returns the dim overlay view so callers can hold it strongly for the export's
// lifetime (see ApolloSVRemoveHUDView).
static UIView *ApolloSVShowHUD(id vc) {
    UIViewController *v = (UIViewController *)vc;
    // The share sheet's own root view is a UIVisualEffectView on iOS 26 — you
    // can't addSubview: to one directly (it asserts). Host the overlay on the
    // window instead (covers the whole sheet, which is what we want for a blocking
    // "preparing…" spinner); fall back to the effect view's contentView.
    UIView *host = v.viewIfLoaded.window;
    if (!host) {
        UIView *root = v.viewIfLoaded;
        host = [root isKindOfClass:[UIVisualEffectView class]]
            ? [(UIVisualEffectView *)root contentView] : root;
    }
    if (![host isKindOfClass:[UIView class]]) return nil;

    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    dim.alpha = 0.0;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    card.layer.cornerRadius = 14.0;
    [dim addSubview:card];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor whiteColor];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [card addSubview:spinner];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Preparing video…";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [card addSubview:label];

    [host addSubview:dim];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:dim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:dim.centerYAnchor],
        [spinner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [spinner.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:spinner.trailingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [label.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [card.heightAnchor constraintEqualToConstant:54],
    ]];

    objc_setAssociatedObject(vc, &kApolloShareVideoHUDKey, dim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(dim, @selector(text), label, OBJC_ASSOCIATION_ASSIGN); // quick label handle
    [UIView animateWithDuration:0.2 animations:^{ dim.alpha = 1.0; }];
    return dim;
}

static void ApolloSVUpdateHUD(id vc, float p) {
    UIView *hud = (UIView *)objc_getAssociatedObject(vc, &kApolloShareVideoHUDKey);
    UILabel *label = [hud isKindOfClass:[UIView class]] ? objc_getAssociatedObject(hud, @selector(text)) : nil;
    if ([label isKindOfClass:[UILabel class]]) {
        int pct = (int)roundf(MAX(0, MIN(1, p)) * 100);
        label.text = [NSString stringWithFormat:@"Preparing video… %d%%", pct];
    }
}

#pragma mark - Share orchestration

// RDKLink.permalink is relative ("/r/.../comments/..."); resolve to an absolute
// reddit URL. Mirrors the Include Link feature so a video share can carry the link.
static NSURL *ApolloSVAbsoluteURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (url.scheme.length > 0 && url.host.length > 0) return url;
    NSString *path = url.absoluteString ?: @"";
    if (path.length == 0) return nil;
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]] ?: url;
}

static NSURL *ApolloSVPostURL(id vc) {
    id link = ApolloSVIvarObject(vc, "link");
    NSURL *u = (NSURL *)ApolloSVCall(link, @selector(permalink));
    if ([u isKindOfClass:[NSURL class]]) return ApolloSVAbsoluteURL(u);
    u = (NSURL *)ApolloSVCall(link, @selector(URL));
    if ([u isKindOfClass:[NSURL class]]) return ApolloSVAbsoluteURL(u);
    return nil;
}

// Supplies the post link to messaging/mail activities (not Save Video / Assign to
// Contact / Print), so an exported video can be shared WITH a tappable link —
// matching how the Include Link option behaves for the image.
@interface ApolloSVLinkItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, strong) NSURL *url;
@end
@implementation ApolloSVLinkItemSource
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)avc { return self.url ?: (id)[NSNull null]; }
- (id)activityViewController:(UIActivityViewController *)avc itemForActivityType:(UIActivityType)t {
    if (!self.url) return nil;
    if ([t isEqualToString:UIActivityTypeSaveToCameraRoll] ||
        [t isEqualToString:UIActivityTypeAssignToContact] ||
        [t isEqualToString:UIActivityTypePrint]) return nil;
    return self.url;
}
@end

static void ApolloSVPresentShare(id vc, NSURL *fileURL) {
    UIViewController *v = (UIViewController *)vc;
    if (!v.viewIfLoaded.window) {
        // VC was dismissed mid-export; clean up the temp file and bail quietly.
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        return;
    }
    // If the (separate) Include Link option is on, attach the post link too — a
    // shared video carries it just like a shared image does.
    NSMutableArray *items = [NSMutableArray arrayWithObject:fileURL];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"ApolloShareAsImageIncludeLink"]) {
        NSURL *postURL = ApolloSVPostURL(vc);
        if (postURL) {
            ApolloSVLinkItemSource *src = [[ApolloSVLinkItemSource alloc] init];
            src.url = postURL;
            [items addObject:src];
        }
    }
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:items applicationActivities:nil];
    avc.completionWithItemsHandler = ^(__unused UIActivityType activityType, __unused BOOL completed,
                                        __unused NSArray *items, __unused NSError *error) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    };
    // iPad popover anchor.
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = v.view;
        avc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(v.view.bounds),
                                                                  CGRectGetMaxY(v.view.bounds) - 40, 1, 1);
    }
    [v presentViewController:avc animated:YES completion:nil];
}

// Re-runs the share, forcing Apollo's native image path (one-shot flag consumed by
// the shareButtonTapped hook). Used when video export can't be produced.
static void ApolloSVFallbackToNative(id vc) {
    if (![vc respondsToSelector:@selector(shareButtonTappedWithSender:)]) return;
    objc_setAssociatedObject(vc, &kApolloShareVideoForceNativeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(shareButtonTappedWithSender:), nil);
}

// Resolves the exportable source for either a post (v.redd.it / direct mp4) or a
// comment (inline Giphy → progressive mp4). Calls back on the main queue.
static void ApolloSVResolveForVC(id vc, void (^completion)(NSURL *videoURL, NSURL *audioURL)) {
    id comment = ApolloSVIvarObject(vc, "comment");
    if (comment) {
        NSURL *mp4 = ApolloSVCommentGiphyMP4(comment);
        ApolloLog(@"[ShareVideo] comment giphy mp4=%@", mp4.absoluteString ?: @"-");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(mp4, nil); });
        return;
    }
    ApolloSVResolveSources(ApolloSVIvarObject(vc, "link"), ^(NSURL *v, NSURL *a, __unused CGSize n) {
        completion(v, a);
    });
}

// Entry point when the user taps Share with the toggle ON. Returns YES if it took
// over the share (caller must NOT call %orig), NO to let the native image share
// proceed.
static BOOL ApolloSVBeginVideoShare(id vc) {
    if ([objc_getAssociatedObject(vc, &kApolloShareVideoExportingKey) boolValue]) return YES; // already in flight

    id comment = ApolloSVIvarObject(vc, "comment");
    BOOL exportable = comment ? ApolloSVCommentExportable(comment)
                              : ApolloSVPostIsExportableVideo(ApolloSVIvarObject(vc, "link"));
    if (!exportable) return NO;

    UIImage *card = ApolloSVCardImage(vc);
    CGRect mediaNorm = CGRectZero;
    if (!card || !ApolloSVMediaRectNormalized(vc, &mediaNorm)) {
        ApolloLog(@"[ShareVideo] card/mediaRect unavailable — falling back to image share");
        return NO;
    }

    objc_setAssociatedObject(vc, &kApolloShareVideoExportingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Hold the HUD overlay STRONGLY in the export blocks below. If the VC is
    // deallocated mid-export, ApolloSVHideHUD (keyed off the VC's associated object)
    // never fires, so without this strong handle the overlay would stay stuck on the
    // window with no way to dismiss it. Capturing the view lets every exit path tear
    // it down regardless of the VC's fate.
    UIView *hud = ApolloSVShowHUD(vc);

    __weak id weakVC = vc;
    ApolloSVResolveForVC(vc, ^(NSURL *videoURL, NSURL *audioURL) {
        id strongVC = weakVC;
        if (!strongVC) { ApolloSVRemoveHUDView(hud); return; }
        if (!videoURL) {
            ApolloLog(@"[ShareVideo] no exportable source — falling back to image share");
            objc_setAssociatedObject(strongVC, &kApolloShareVideoExportingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloSVHideHUD(strongVC);
            // Best-effort: re-trigger the native (image) share so the tap isn't lost.
            ApolloSVFallbackToNative(strongVC);
            return;
        }
        ApolloSVExport(strongVC, card, mediaNorm, videoURL, audioURL,
            ^(float p) { ApolloSVUpdateHUD(weakVC, p); },
            ^(NSURL *outURL, NSError *error) {
                id sVC = weakVC;
                if (!sVC) {
                    ApolloSVRemoveHUDView(hud); // VC gone — tear the overlay down ourselves
                    if (outURL) [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                    return;
                }
                objc_setAssociatedObject(sVC, &kApolloShareVideoExportingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloSVHideHUD(sVC);
                if (outURL && !error) {
                    ApolloSVPresentShare(sVC, outURL);
                } else {
                    // Soft failure: fall back to Apollo's image share.
                    ApolloSVFallbackToNative(sVC);
                }
            });
    });
    return YES;
}

#pragma mark - Options row UI

static void ApolloSVInstallRow(id vc) {
    if (!vc) return;
    if (objc_getAssociatedObject(vc, &kApolloShareVideoSwitchKey)) return; // already built

    // Shown for video posts AND for comments carrying an exportable inline GIF.
    id comment = ApolloSVIvarObject(vc, "comment");
    BOOL isVideo = comment ? ApolloSVCommentExportable(comment)
                           : ApolloSVPostIsExportableVideo(ApolloSVIvarObject(vc, "link"));
    objc_setAssociatedObject(vc, &kApolloShareVideoIsVideoKey, @(isVideo), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!isVideo) {
        ApolloLog(@"[ShareVideo] viewDidLoad: no exportable %@ media — no row", comment ? @"comment" : @"post");
        return;
    }

    UILabel *watermarkLabel = (UILabel *)ApolloSVIvarObject(vc, "watermarkRowTitleLabel");
    UISwitch *watermarkSwitch = (UISwitch *)ApolloSVIvarObject(vc, "watermarkRowSwitch");
    if (![watermarkLabel isKindOfClass:[UILabel class]] || ![watermarkSwitch isKindOfClass:[UISwitch class]]) {
        ApolloLog(@"[ShareVideo] watermark row not found — skipping row");
        return;
    }
    UIView *container = watermarkLabel.superview;
    if (!container) return;

    UILabel *label = [[UILabel alloc] init];
    label.text = kApolloShareVideoTitle;
    label.font = watermarkLabel.font;
    label.textColor = watermarkLabel.textColor;
    label.textAlignment = watermarkLabel.textAlignment;
    label.numberOfLines = watermarkLabel.numberOfLines;
    [container addSubview:label];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = watermarkSwitch.onTintColor;
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:kApolloShareVideoKey];
    [toggle addTarget:vc action:@selector(apollo_shareVideoToggled:) forControlEvents:UIControlEventValueChanged];
    [container addSubview:toggle];

    UIView *separator = [[UIView alloc] init];
    NSArray *separators = (NSArray *)ApolloSVIvarObject(vc, "separators");
    UIView *templateSep = [separators isKindOfClass:[NSArray class]] ? [separators lastObject] : nil;
    separator.backgroundColor = [templateSep isKindOfClass:[UIView class]]
        ? templateSep.backgroundColor : [UIColor colorWithWhite:0.5 alpha:0.3];
    [container addSubview:separator];

    objc_setAssociatedObject(vc, &kApolloShareVideoLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kApolloShareVideoSwitchKey, toggle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kApolloShareVideoSeparatorKey, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[ShareVideo] options row installed (on=%d)", (int)toggle.on);
}

// Width helper: prefer the native separator width, fall back to the label's.
static CGFloat ApolloSVRowWidth(id vc, CGRect wl) {
    NSArray *separators = (NSArray *)ApolloSVIvarObject(vc, "separators");
    UIView *templateSep = [separators isKindOfClass:[NSArray class]] ? [separators lastObject] : nil;
    if ([templateSep isKindOfClass:[UIView class]] && templateSep.frame.size.width > 1) return templateSep.frame.size.width;
    return wl.size.width;
}

// Anchors our row at the Share button's CURRENT position and pushes the button
// down by one row. Runs AFTER %orig, so whatever native/other modules placed the
// button, we stack below it — no coupling to other added rows.
static void ApolloSVLayoutRow(id vc) {
    UILabel *label = (UILabel *)objc_getAssociatedObject(vc, &kApolloShareVideoLabelKey);
    UISwitch *toggle = (UISwitch *)objc_getAssociatedObject(vc, &kApolloShareVideoSwitchKey);
    UIView *separator = (UIView *)objc_getAssociatedObject(vc, &kApolloShareVideoSeparatorKey);
    if (!label || !toggle) return;

    UILabel *watermarkLabel = (UILabel *)ApolloSVIvarObject(vc, "watermarkRowTitleLabel");
    UISwitch *watermarkSwitch = (UISwitch *)ApolloSVIvarObject(vc, "watermarkRowSwitch");
    UIView *shareButton = (UIView *)ApolloSVIvarObject(vc, "shareButton");
    if (![watermarkLabel isKindOfClass:[UILabel class]] || ![watermarkSwitch isKindOfClass:[UISwitch class]] ||
        ![shareButton isKindOfClass:[UIView class]]) return;

    CGRect wl = watermarkLabel.frame;
    CGRect ws = watermarkSwitch.frame;

    // Place our row one row-pitch below the row directly above it, so the spacing
    // matches the native rows (rather than inheriting the larger row→button gap).
    // Whatever placed the Share button put it at (rowAbove.maxY + buttonGap), so
    // rowAbove.label.y = button.y - labelHeight - buttonGap, and our row sits one
    // pitch below that: button.y + pitch - labelHeight - buttonGap.
    double pitch = ApolloSVIvarDouble(vc, "rowHeight");
    if (pitch <= 1.0 || !isfinite(pitch)) pitch = wl.size.height + 16.0;
    CGRect bf = shareButton.frame;
    CGFloat rowY = bf.origin.y + pitch - wl.size.height - kApolloShareVideoButtonGap;

    CGFloat labelW = MAX(wl.size.width, ws.origin.x - 8.0 - wl.origin.x);
    label.frame = CGRectMake(wl.origin.x, rowY, labelW, wl.size.height);
    // Switch keeps its native x; vertically centred against the label.
    toggle.frame = CGRectMake(ws.origin.x, rowY + (wl.size.height - ws.size.height) / 2.0,
                              ws.size.width, ws.size.height);

    if (separator) {
        CGFloat hair = 1.0 / [UIScreen mainScreen].scale;
        separator.frame = CGRectMake(wl.origin.x, CGRectGetMaxY(label.frame) - hair, ApolloSVRowWidth(vc, wl), hair);
    }

    // Push the Share button below our row.
    bf.origin.y = CGRectGetMaxY(label.frame) + kApolloShareVideoButtonGap;
    shareButton.frame = bf;
}

#pragma mark - Hooks

%hook _TtC6Apollo26ShareAsImageViewController

- (void)viewDidLoad {
    %orig;
    ApolloSVInstallRow(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSVLayoutRow(self);
}

%new
- (void)apollo_shareVideoToggled:(UISwitch *)sender {
    BOOL on = [sender isKindOfClass:[UISwitch class]] ? sender.isOn : NO;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kApolloShareVideoKey];
    ApolloLog(@"[ShareVideo] toggle -> %d", (int)on);
}

- (void)shareButtonTappedWithSender:(id)sender {
    // One-shot fallback: a prior video-export attempt failed and asked for the
    // native image share. Consume the flag and go straight to %orig.
    if ([objc_getAssociatedObject(self, &kApolloShareVideoForceNativeKey) boolValue]) {
        objc_setAssociatedObject(self, &kApolloShareVideoForceNativeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig;
        return;
    }
    BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:kApolloShareVideoKey];
    BOOL isVideo = [objc_getAssociatedObject(self, &kApolloShareVideoIsVideoKey) boolValue];
    if (on && isVideo && ![objc_getAssociatedObject(self, &kApolloShareVideoExportingKey) boolValue]) {
        if (ApolloSVBeginVideoShare(self)) {
            ApolloLog(@"[ShareVideo] took over share (video export)");
            return; // suppress native image share
        }
    }
    %orig;
}

%end

// Grow the bottom sheet by one row when our row is installed (video posts), so the
// relocated Share button isn't clipped. Mirrors the loop-free approach used by
// ApolloShareAsImageLink; gated on our row's presence so non-video posts (and
// other modules' rows) are unaffected by us.
%hook _TtC6Apollo31SourdoughPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    @try {
        if (!isfinite(frame.origin.y) || !isfinite(frame.size.height) || frame.size.height <= 1.0) return frame;
        id presented = [(UIPresentationController *)self presentedViewController];
        Class shareVCClass = objc_getClass("_TtC6Apollo26ShareAsImageViewController");
        if (shareVCClass && [presented isKindOfClass:shareVCClass] &&
            objc_getAssociatedObject(presented, &kApolloShareVideoSwitchKey)) {
            double pitch = ApolloSVIvarDouble(presented, "rowHeight");
            if (pitch <= 1.0 || !isfinite(pitch)) pitch = 50.0;
            // Our row is one pitch below the row above it (even spacing) and the
            // button follows below it, so the sheet needs exactly one more row of
            // height.
            CGFloat grow = pitch;
            CGFloat nativeBottom = frame.origin.y + frame.size.height;
            CGFloat newTop = MAX(0.0, frame.origin.y - grow);
            frame.origin.y = newTop;
            frame.size.height = nativeBottom - newTop;
        }
    } @catch (__unused NSException *e) {}
    return frame;
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo26ShareAsImageViewController")) {
            %init();
            ApolloLog(@"[ShareVideo] module loaded");
        } else {
            ApolloLog(@"[ShareVideo] ShareAsImageViewController not found — skipping");
        }
    }
}
