// ApolloLinkPreviewShapeMemory.h
//
// Per-host memory of whether a site's rich link previews actually carry a
// usable hero image.
//
// WHY THIS EXISTS
// ---------------
// When a link card is measured for a URL we have never fetched, the renderer
// has to pick a card shape *before* it knows anything about the page, and the
// two shapes have wildly different heights (a hero reserves a 16:9 image box —
// ~220pt at feed width — while a compact card is ~104pt). Guessing "hero" and
// then discovering the page has no image forces a shrink, and a shrink can only
// be committed by a table row reload, which is exactly the fragile machinery
// behind the recurring "compact card stranded inside a full-card-height row,
// heals later while scrolling" reports.
//
// The asymmetry matters: a wrong *compact* guess only ever grows the row (which
// Texture's ordinary height refresh and the V18 overflow check both handle),
// while a wrong *hero* guess strands the row. So the renderer should predict
// compact whenever it has any real evidence, and the cheapest evidence is what
// already happened: hosts like nature.com, doi.org, or a paywall/Cloudflare
// wall never yield an og:image, and they yield it consistently.
//
// This store remembers that verdict per host, PERSISTS it across launches, and
// answers in O(1) from Texture's background layout threads. With it, a host you
// have seen before renders the right shape on the very first measure and no
// relayout of any kind is needed.
//
// Storage lives next to the preview cache in Caches/ and is disposable.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ApolloLPHostShape) {
    /// No evidence, or MIXED evidence (some previews imageful, some not — the
    /// paywalled-news case: wsj.com and reuters.com serve og:image on free
    /// articles and 401 on the rest). Mixed deliberately reports Unknown rather
    /// than Imaged: "sometimes" is not evidence that THIS url will have an image.
    ApolloLPHostShapeUnknown = 0,
    /// Every preview we have seen from this host resolved without a usable image.
    ApolloLPHostShapeImageless,
    /// Every preview we have seen from this host carried a usable image, and none
    /// ever did not. This is the ONLY verdict strong enough to justify reserving
    /// a hero-sized image box before the fetch comes back.
    ApolloLPHostShapeImaged,
};

@interface ApolloLinkPreviewShapeMemory : NSObject

+ (instancetype)sharedMemory;

/// Hot path: safe to call from Texture background layout threads.
/// `host` is expected already lowercased and `www.`-stripped, but is
/// normalised defensively anyway.
- (ApolloLPHostShape)shapeForHost:(NSString *)host;

/// Record one observation. Called once per completed preview fetch, never from
/// a layout pass.
- (void)recordHost:(NSString *)host hasUsableImage:(BOOL)hasUsableImage;

/// The page advertised an og:image but the file 4xx'd. Retracts the optimistic
/// observation `recordHost:hasUsableImage:YES` already made for it, so a host
/// that habitually advertises images it never serves converges to imageless
/// instead of being pinned to a hero placeholder by its own broken metadata.
/// Called once per image URL, from the dead-image mark.
- (void)recordHostAdvertisedImageWasDead:(NSString *)host;

/// Seed the store from the on-disk preview cache the first time it is used, so
/// existing users get an accurate, personalised memory immediately instead of
/// re-learning every host one stranded row at a time. No-op afterwards.
/// Safe to call from any thread; work happens off the caller's thread.
- (void)primeFromPreviewCacheIfNeeded;

/// Forget everything (paired with the settings "clear preview cache" action).
- (void)reset;

@end
