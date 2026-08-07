#import <Foundation/Foundation.h>

#import "ApolloLinkPreviewModel.h"

@interface ApolloLinkPreviewFetcher : NSObject

+ (void)requestPreviewForURL:(NSURL *)url completion:(void (^)(ApolloLinkPreview *preview))completion;
+ (BOOL)isTwitterURL:(NSURL *)url;

// Non-nil when a CACHED preview is the residue of a fetch that never reached
// the real page — a bot-wall interstitial title, a DOI page whose metadata is
// just the DOI, or the slug-title + favicon fallback with no description — and
// therefore deserves a background refetch rather than squatting in the cache
// for its whole TTL. Returns a short reason slug for logging ("bot-wall",
// "weak-academic", "weak-generic") or nil for a healthy preview. Shared by
// requestPreviewForURL:'s own staleness gate and the render path's
// once-per-launch cache-healing kick in ApolloInlineLinkPreviews.
+ (NSString *)refetchReasonForCachedPreview:(ApolloLinkPreview *)preview url:(NSURL *)url;

@end

// Decode HTML entities (named + numeric, e.g. &laquo;->«, &raquo;->», &#8230;->…)
// for display-time callers in other translation units. The fetcher decodes these
// when it first stores metadata, but cached and *translated* link-card text bypass
// that path and would otherwise render raw — so the render choke point decodes too.
FOUNDATION_EXPORT NSString *ApolloLinkPreviewDecodeEntities(NSString *string);
