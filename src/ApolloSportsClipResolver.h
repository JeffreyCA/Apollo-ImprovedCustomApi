// ApolloSportsClipResolver.h
//
// "Sports Clip Links Play Inline": makes short-clip host links (streamff.pro,
// streamin.link, streamain.com, bangr.im, dubz.link, dropr.co, MLB clip CDNs —
// the hosts r/soccer, r/formula1, r/baseball, etc. use for goal/highlight clips)
// play inline exactly like Streamable links do, instead of rendering as a
// link-preview card.
//
// How: Apollo's whole Streamable pipeline is generic after recognition — one
// host regex classifies the post, then VideoClient fetches
// api.streamable.com/videos/<shortcode> and plays the mp4 it returns through
// the ordinary inline AVPlayer path. So the tweak (ApolloSportsClips.xm):
//   1. widens that recognition regex to also match the sports hosts (the
//      ApolloRedgifsSubdomainFix technique — one initWithPattern: hook covers
//      every classifier call site at once);
//   2. records clipID -> host in a side table when the widened regex matches a
//      sports URL (so the model's URL is never rewritten — copy-link/open-in-
//      browser stay honest);
//   3. intercepts the resulting api.streamable.com/videos/<clipID>[.json]
//      fetch (same NSURLSession fabrication technique as the Imgur DDG proxy
//      in Tweak.xm) and answers it with a synthesized Streamable-shaped JSON
//      whose mp4/poster were resolved from the sports host by this file.
//
// The synthesized JSON must satisfy Apollo's StreamableVideo Unbox decode,
// which requires ALL of: files.mp4.url, files.mp4.width, files.mp4.duration,
// thumbnail_url (files.mp4-mobile.url optional; height/status/percent are
// ignored). Width/duration are not knowable cheaply for most hosts, so
// plausible defaults are synthesized — the player reads real dimensions and
// duration from the media itself.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// This file is plain Objective-C but its callers are Logos .xm files compiled
// as Objective-C++; keep C linkage so the symbols resolve.
#ifdef __cplusplus
extern "C" {
#endif

// Master toggle (UDKeySportsClipsInlineVideo).
BOOL ApolloSportsClipsEnabled(void);

// Returns a widened copy of Apollo's Streamable recognition regex (original or
// the query-string variant ApolloMedia.xm swaps in — hook chaining order means
// either may arrive first), or the input unchanged for every other pattern or
// when the feature is disabled.
NSString *ApolloSportsClipsWidenPatternIfNeeded(NSString *pattern);

// YES if `pattern` is the widened recognition regex produced above.
BOOL ApolloSportsClipsIsWidenedPattern(NSString *pattern);

// Called when the widened regex matched `urlString` capturing `clipID`.
// Registers clipID -> (host kind, original URL) in the side table when the URL
// belongs to a sports host; a real streamable.com match is ignored.
void ApolloSportsClipsNoteRecognizedURL(NSString *urlString, NSString *clipID);

// YES if `clipID` was registered as a sports clip this session.
BOOL ApolloSportsClipsHasID(NSString *clipID);

// Resolves a registered clip to a ready-to-serialize Streamable-shaped JSON
// dictionary (nil on failure: dead clip, takedown placeholder, scrape miss).
// Results are cached (short TTL). Completion may fire on any queue.
void ApolloSportsClipsResolveID(NSString *clipID, void (^completion)(NSDictionary *streamableJSON));

// YES when `url` belongs to a supported sports-clip host (toggle-independent;
// callers gate on ApolloSportsClipsEnabled themselves).
BOOL ApolloSportsClipsIsSportsHostURL(NSURL *url);

// Resolves a sports-clip page URL straight to its playable media, for the
// ApolloHostedVideo share paths (Share as Video / Share as Image gallery).
// Unlike ApolloSportsClipsResolveID this needs no prior side-table
// registration — kind and id are re-derived from the URL — so it works even
// for posts whose feed cell never classified (e.g. shared from a search
// result). mp4URL nil on failure; posterURL nil when the host exposes no real
// poster; pixelSize CGSizeZero when unknown. Completion may fire on any queue.
void ApolloSportsClipsResolvePageURL(NSURL *pageURL,
                                     void (^completion)(NSURL *mp4URL, NSURL *posterURL, CGSize pixelSize));

#ifdef __cplusplus
}
#endif
