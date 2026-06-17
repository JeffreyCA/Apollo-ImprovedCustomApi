// ApolloFeedTextPostThumbnails.xm
//
// Gives self/text posts a real feed thumbnail when the post body embeds media
// (Reddit-uploaded images via media_metadata, or direct external image links in
// the selftext) but Reddit/Apollo produced no native thumbnail. Without this,
// such posts show a bare link card in large mode and a grey placeholder square
// in compact mode.
//
// Strategy A (non-invasive): we only set the existing thumbnail node's URL on
// the affected cells (compact) or inject a hero node above Apollo's content
// (large). Eligible posts stay self posts; tapping the title/body still opens
// the post.
//
// Consistency additions (issue #419):
//   * Settings toggle (Media > Text Post Thumbnails, default ON; off restores
//     Apollo's native no-thumbnail behavior for text posts).
//   * A "Text Post" pill on the large-mode hero so these thumbnails are
//     distinguishable from image posts in the feed.
//   * Tapping the thumbnail opens the embedded image(s) in a fullscreen
//     zoomable viewer — same expectation as tapping an image post — instead
//     of opening the thread.
//
// Eligibility (strict): act ONLY when
//   * link.selfPost == YES, AND
//   * the link has no usable native media (no http(s) thumbnailURL, no
//     previewMedia.sourceImage, no gallery, no video), AND
//   * we can derive at least one embedded image URL from media_metadata or the
//     selftext.
// This guarantees normal image/gallery/video/link posts are untouched.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloMediaMetadata.h"
#import "ApolloState.h"
#import "Tweak.h"

// Tweak.h's RDKLink declares selfPost/selfText/mediaMetadata/previewMedia. The
// native-media gate also needs these media accessors — declare them here so the
// compiler knows the selectors (they exist on the real runtime class).
@interface RDKLink (ApolloFeedThumb)
@property (readonly, copy, nonatomic) NSURL *thumbnailURL;
@property (retain, nonatomic) id gallery;
@property (retain, nonatomic) id internalGallery;
@property (retain, nonatomic) id mediaVideo;
@property (retain, nonatomic) id previewVideo;
@property (retain, nonatomic) id crossPostVideo;
@property (readonly, nonatomic) id video;
@end

// ASSizeRange — matches Apollo's class-dumped CDStruct_90e057aa ABI.
struct ApolloFeedThumbSizeRange { CGSize min; CGSize max; };

// MARK: - Minimal Texture (AsyncDisplayKit) surface

typedef NS_ENUM(unsigned char, ApolloFeedStackDirection) {
    ApolloFeedStackDirectionVertical = 0,
    ApolloFeedStackDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloFeedStackJustify) {
    ApolloFeedStackJustifyStart = 0,
    ApolloFeedStackJustifyCenter = 1,
    ApolloFeedStackJustifyEnd = 2,
};
typedef NS_ENUM(unsigned char, ApolloFeedStackAlign) {
    ApolloFeedStackAlignStart = 0,
    ApolloFeedStackAlignEnd = 1,
    ApolloFeedStackAlignCenter = 2,
    ApolloFeedStackAlignStretch = 3,
};

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (id)style;
- (UIView *)view;
- (CALayer *)layer;
- (BOOL)isNodeLoaded;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nullable, nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nullable, nonatomic, copy) UIColor *placeholderColor;
@property (nonatomic) BOOL placeholderEnabled;@property (nonatomic) NSTimeInterval placeholderFadeDuration;
@property (nonatomic, weak) id delegate;
// ASImageNode is an ASControlNode subclass, so target-action is available.
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)controlEvents;
@end

// ASControlNodeEventTouchUpInside from Texture's ASControlNode.h.
static const NSUInteger ApolloFeedControlEventTouchUpInside = 1 << 4;

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloFeedStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloFeedStackJustify justifyContent;
@property (nonatomic) ApolloFeedStackAlign alignItems;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloFeedStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloFeedStackJustify)justifyContent
                                  alignItems:(ApolloFeedStackAlign)alignItems
                                    children:(NSArray *)children;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

// ASLayoutElementStyle subset for fixing the hero height.
@interface ApolloFeedLayoutStyle : NSObject
@property (nonatomic) CGSize preferredSize;
@property (nonatomic) CGSize minSize;
@property (nonatomic) CGSize maxSize;
@end

// Minimal ASNetworkImageNode surface we touch on Apollo's existing thumbnail nodes.
@interface ApolloFeedThumbImageNode : NSObject
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@end

// Associated-object cache: resolved thumbnail URL per RDKLink (or NSNull when
// the link was evaluated and produced nothing). Survives cell reuse because the
// hooks always re-read the live `link` ivar.
static char kApolloFeedThumbURLKey;

// Associated-object cache: aspect ratio (height/width) of the chosen image, used
// to size the injected large-mode hero node. Stored as an NSNumber.
static char kApolloFeedThumbRatioKey;

// Associated-object: the ASNetworkImageNode we inject into a RichMediaNode's
// layout for large-mode text/link posts (created once per node, reused).
static char kApolloFeedHeroNodeKey;

// Apollo's standard large-cell horizontal content margin (matches the feed
// search bar and the title/body text), so the rounded hero lines up with the
// rest of the cell instead of bleeding to the screen edge.
static const CGFloat kApolloFeedHeroSideInset = 16.0;

// Associated-object on the hero node: the RDKLink it currently displays
// (updated every layout pass — cells get reused for different links).
static char kApolloFeedHeroLinkKey;

// Associated-object on an RDKLink: cached full-resolution viewer items
// (NSArray<NSDictionary *> with @"url"), used when the hero is tapped.
static char kApolloFeedViewerItemsKey;

// NSNumber(BOOL) on a compact thumbnail node: our tap target is attached.
static char kApolloFeedCompactTapWiredKey;

// Shared ASNetworkImageNode delegate that fades the hero image in once it
// finishes loading. ASNetworkImageNode's placeholderFadeDuration only fades the
// (near-transparent) placeholder layer out, so the downloaded image still
// "pops" in. We add an explicit one-shot opacity animation on the node's layer
// when the image lands, which reads as a real fade regardless of cache hits.
@interface ApolloFeedHeroFadeDelegate : NSObject
@end

@implementation ApolloFeedHeroFadeDelegate
+ (instancetype)shared {
    static ApolloFeedHeroFadeDelegate *sShared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sShared = [[ApolloFeedHeroFadeDelegate alloc] init]; });
    return sShared;
}

- (void)fadeInNode:(id)node {
    if (!node) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ASDisplayNode *n = (ASDisplayNode *)node;
            if (![n isNodeLoaded]) return;
            CALayer *layer = [n layer];
            if (!layer) return;
            CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue = @0.0;
            fade.toValue = @1.0;
            fade.duration = 0.3;
            fade.removedOnCompletion = YES;
            [layer addAnimation:fade forKey:@"apolloFeedHeroFade"];
        } @catch (__unused NSException *e) {}
    });
}

// Older delegate selector (image arg only).
- (void)imageNode:(id)node didLoadImage:(id)image {
    if (image) [self fadeInNode:node];
}

// Newer delegate selector (with info).
- (void)imageNode:(id)node didLoadImage:(id)image info:(id)info {
    if (image) [self fadeInNode:node];
}
@end

// Master switch lives in ApolloState (sFeedTextPostThumbnails), hydrated from
// UDKeyFeedTextPostThumbnails and toggled from the Media settings section.
// Off restores Apollo's native behavior (no thumbnails on text posts).

#pragma mark - URL helpers

// Direct external image URL allowlist for selftext-embedded links. Requires an
// image file extension on a known media CDN host, and rejects mp4-format GIFs.
static BOOL ApolloFeedIsDirectImageURLString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    NSString *lower = s.lowercaseString;
    if ([lower containsString:@"format=mp4"]) return NO;

    NSURL *url = [NSURL URLWithString:s];
    NSString *path = url.path.lowercaseString;
    if (path.length == 0) path = lower;
    BOOL imageExt = [path hasSuffix:@".png"] || [path hasSuffix:@".jpg"] ||
                    [path hasSuffix:@".jpeg"] || [path hasSuffix:@".webp"] ||
                    [path hasSuffix:@".gif"];
    if (!imageExt) return NO;

    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;

    static NSArray<NSString *> *suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[ @"redd.it", @"imgur.com", @"giphy.com", @"tenor.com",
                      @"redgifs.com", @"twimg.com", @"discordapp.com",
                      @"discordapp.net", @"imgchest.com" ];
    });
    for (NSString *suf in suffixes) {
        if ([host isEqualToString:suf] ||
            [host hasSuffix:[@"." stringByAppendingString:suf]]) {
            return YES;
        }
    }
    return NO;
}

// Best static-preview URL string for a single media_metadata entry. Prefers the
// largest p[] preview (signed, sized, static — good for both modes and avoids
// animating GIF entries in the feed), falling back to the canonical display URL.
static NSString *ApolloFeedStaticPreviewURLFromEntry(NSString *assetID, NSDictionary *entry) {
    NSArray *previews = entry[@"p"];
    if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
        NSDictionary *best = nil;
        long long bestArea = -1;
        for (NSDictionary *pv in previews) {
            if (![pv isKindOfClass:[NSDictionary class]]) continue;
            NSString *u = pv[@"u"];
            if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
            long long area = [pv[@"x"] longLongValue] * [pv[@"y"] longLongValue];
            if (area >= bestArea) { bestArea = area; best = pv; }
        }
        NSString *u = best[@"u"];
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            return [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        }
    }
    return ApolloMediaDisplayURLFromMetadataEntry(assetID, entry, NO);
}

// Source dimensions for a single media_metadata entry (falls back to largest
// preview if the canonical source size is absent). Returns area; fills w/h.
static long long ApolloFeedEntryDimensions(NSDictionary *entry, long long *outW, long long *outH) {
    long long w = 0, h = 0;
    NSDictionary *s = entry[@"s"];
    if ([s isKindOfClass:[NSDictionary class]]) {
        w = [s[@"x"] longLongValue];
        h = [s[@"y"] longLongValue];
    }
    if (w <= 0 || h <= 0) {
        NSArray *previews = entry[@"p"];
        if ([previews isKindOfClass:[NSArray class]]) {
            long long bestArea = 0;
            for (NSDictionary *pv in previews) {
                if (![pv isKindOfClass:[NSDictionary class]]) continue;
                long long pw = [pv[@"x"] longLongValue];
                long long ph = [pv[@"y"] longLongValue];
                if (pw * ph > bestArea) { bestArea = pw * ph; w = pw; h = ph; }
            }
        }
    }
    if (outW) *outW = w;
    if (outH) *outH = h;
    return w * h;
}

// YES when an entry is a valid still/animated image in media_metadata.
static BOOL ApolloFeedEntryIsImage(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return NO;
    NSString *status = entry[@"status"];
    if ([status isKindOfClass:[NSString class]] && ![status isEqualToString:@"valid"]) return NO;
    NSString *e = entry[@"e"];
    return [e isKindOfClass:[NSString class]] &&
           ([e isEqualToString:@"Image"] || [e isEqualToString:@"AnimatedImage"]);
}

// The FIRST embedded image in the post body. media_metadata is an unordered
// dictionary keyed by asset ID; the asset ID also appears inside the body's
// preview.redd.it URLs, so we order entries by where their key first occurs in
// the selftext. If the first image is tiny (would look bad stretched as a
// thumbnail), we fall back to the largest image instead.
// Outputs the chosen image's aspect ratio (height/width) when known.
static NSURL *ApolloFeedThumbURLFromMediaMetadata(NSDictionary *mediaMetadata,
                                                  NSString *selfText,
                                                  CGFloat *outRatio) {
    if (outRatio) *outRatio = 0.0;
    if (![mediaMetadata isKindOfClass:[NSDictionary class]] || mediaMetadata.count == 0) {
        return nil;
    }

    NSString *body = [selfText isKindOfClass:[NSString class]] ? selfText : @"";

    NSString *firstKey = nil;       NSDictionary *firstEntry = nil;
    NSUInteger firstIndex = NSNotFound;
    NSString *largestKey = nil;     NSDictionary *largestEntry = nil;
    long long largestArea = -1;

    for (NSString *assetID in mediaMetadata) {
        NSDictionary *entry = mediaMetadata[assetID];
        if (!ApolloFeedEntryIsImage(entry)) continue;

        long long area = ApolloFeedEntryDimensions(entry, NULL, NULL);
        if (area >= largestArea) { largestArea = area; largestKey = assetID; largestEntry = entry; }

        // Order by first appearance of the asset key in the body markdown.
        NSRange r = [body rangeOfString:assetID];
        NSUInteger idx = (r.location != NSNotFound) ? r.location : NSNotFound;
        if (idx != NSNotFound && (firstIndex == NSNotFound || idx < firstIndex)) {
            firstIndex = idx; firstKey = assetID; firstEntry = entry;
        }
    }

    // Choose the first body image; if none could be ordered, use the largest.
    NSString *chosenKey = firstEntry ? firstKey : largestKey;
    NSDictionary *chosenEntry = firstEntry ?: largestEntry;
    if (!chosenEntry) return nil;

    // Size guard: a very small first image stretched as a hero looks bad, so
    // prefer the largest image when the first one is tiny.
    long long cw = 0, ch = 0;
    ApolloFeedEntryDimensions(chosenEntry, &cw, &ch);
    long long maxDim = MAX(cw, ch);
    if (maxDim > 0 && maxDim < 250 && largestEntry && largestEntry != chosenEntry) {
        chosenKey = largestKey;
        chosenEntry = largestEntry;
        ApolloFeedEntryDimensions(chosenEntry, &cw, &ch);
    }

    if (outRatio && cw > 0 && ch > 0) *outRatio = (CGFloat)((double)ch / (double)cw);

    NSString *urlString = ApolloFeedStaticPreviewURLFromEntry(chosenKey, chosenEntry);
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    return [NSURL URLWithString:urlString];
}

// First direct image URL found in the selftext (markdown body).
static NSURL *ApolloFeedThumbURLFromSelfText(NSString *selfText) {
    if (![selfText isKindOfClass:[NSString class]] || selfText.length == 0) return nil;

    static NSDataDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    });
    if (!detector) return nil;

    __block NSURL *found = nil;
    [detector enumerateMatchesInString:selfText
                               options:0
                                 range:NSMakeRange(0, selfText.length)
                            usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSURL *u = match.URL;
        if (u && ApolloFeedIsDirectImageURLString(u.absoluteString)) {
            found = u;
            *stop = YES;
        }
    }];
    return found;
}

#pragma mark - Eligibility

// Resolve (and cache) the thumbnail URL for an eligible self/text post.
// Returns nil for ineligible posts or when no embedded image was found.
// Deliberately NOT gated on sFeedTextPostThumbnails — the toggle-off path
// still needs eligibility to strip raw image URLs from preview text.
static NSURL *ApolloFeedThumbnailURLForLink(RDKLink *link) {
    if (!link) return nil;

    id cached = objc_getAssociatedObject(link, &kApolloFeedThumbURLKey);
    if (cached) {
        return (cached == [NSNull null]) ? nil : (NSURL *)cached;
    }

    NSURL *result = nil;
    BOOL isSelf = NO;
    CGFloat ratio = 0.0; // height/width of the chosen image, if known
    @try {
        isSelf = link.selfPost;
        NSDictionary *mm = link.mediaMetadata;
        NSString *st = link.selfText;
        if (isSelf) {
            // For self/text posts we only surface an image that actually lives
            // in the post itself: an embedded media_metadata image, or a direct
            // image URL pasted in the body / used as the link target. We do NOT
            // use Apollo's scraped link preview (thumbnailURL / previewMedia
            // sourceImage) — those are low-res website OG images that look awful
            // blown up as a hero. A post that only contains a non-image link
            // should just render as a normal text post (no thumbnail).
            // Priority: media_metadata > selftext image link > link.URL image.
            result = ApolloFeedThumbURLFromMediaMetadata(mm, st, &ratio);
            if (!result) result = ApolloFeedThumbURLFromSelfText(st);
            if (!result) {
                NSURL *u = link.URL;
                if ([u isKindOfClass:[NSURL class]] &&
                    ApolloFeedIsDirectImageURLString(u.absoluteString)) {
                    result = u;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    // Clamp the hero aspect ratio to a sane band; default to a wide-ish hero.
    if (result) {
        if (ratio <= 0.0) ratio = 0.56;
        if (ratio < 0.3) ratio = 0.3;
        if (ratio > 1.2) ratio = 1.2;
        objc_setAssociatedObject(link, &kApolloFeedThumbRatioKey,
                                 @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(link, &kApolloFeedThumbURLKey,
                             result ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

#pragma mark - Fullscreen viewer plumbing

// Full-resolution viewer items for an eligible text post: every embedded
// media_metadata image, ordered by first occurrence in the selftext (same
// ordering rule as the thumbnail choice), as @{ @"url": NSURL } dictionaries
// for ApolloPresentImageChestItems. Falls back to the single thumbnail URL
// for selftext-link images. Cached per link.
static NSArray<NSDictionary *> *ApolloFeedViewerItemsForLink(RDKLink *link) {
    if (!link) return @[];
    NSArray *cached = objc_getAssociatedObject(link, &kApolloFeedViewerItemsKey);
    if ([cached isKindOfClass:[NSArray class]]) return cached;

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    @try {
        NSDictionary *mediaMetadata = link.mediaMetadata;
        NSString *body = [link.selfText isKindOfClass:[NSString class]] ? link.selfText : @"";
        if ([mediaMetadata isKindOfClass:[NSDictionary class]] && mediaMetadata.count > 0) {
            NSMutableArray<NSString *> *keys = [NSMutableArray array];
            for (NSString *assetID in mediaMetadata) {
                if (ApolloFeedEntryIsImage(mediaMetadata[assetID])) [keys addObject:assetID];
            }
            // Body order; images never referenced in the body sort last
            // (NSNotFound compares greater than any real index).
            [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSUInteger ia = [body rangeOfString:a].location;
                NSUInteger ib = [body rangeOfString:b].location;
                if (ia == ib) return NSOrderedSame;
                return ia < ib ? NSOrderedAscending : NSOrderedDescending;
            }];
            for (NSString *assetID in keys) {
                NSString *urlString = ApolloMediaDisplayURLFromMetadataEntry(assetID, mediaMetadata[assetID], NO);
                NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
                if (url) [items addObject:@{ @"url": url }];
            }
        }
        if (items.count == 0) {
            NSURL *thumb = ApolloFeedThumbnailURLForLink(link);
            if (thumb) [items addObject:@{ @"url": thumb }];
        }
    } @catch (__unused NSException *e) {}

    objc_setAssociatedObject(link, &kApolloFeedViewerItemsKey, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return items;
}

// Route an image URL into Apollo's native link-tap machinery by walking the
// supernode chain for textNode:tappedLinkAttribute:value:atPoint:textRange:
// (RichMediaNode and LargePostCellNode implement it). With the "ApolloLink"
// attribute, Apollo routes direct image URLs into its native MediaViewer —
// identical to tapping an image link anywhere else in the app. Returns NO
// when no handler exists in the chain (e.g. compact cells).
static BOOL ApolloFeedRouteURLToNativeHandler(id startNode, NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    SEL sel = @selector(textNode:tappedLinkAttribute:value:atPoint:textRange:);
    id target = startNode;
    for (int hops = 0; target && hops < 24; hops++) {
        if ([target respondsToSelector:sel]) break;
        target = [target respondsToSelector:@selector(supernode)] ? [target supernode] : nil;
    }
    if (!target) return NO;

    ApolloLog(@"[FeedThumb] routing %@ to native viewer via %@", url.host, NSStringFromClass([target class]));
    void (*msgSend)(id, SEL, id, id, id, CGPoint, NSRange) =
        (void (*)(id, SEL, id, id, id, CGPoint, NSRange))objc_msgSend;
    msgSend(target, sel, target, @"ApolloLink", url, CGPointZero, NSMakeRange(NSNotFound, 0));
    return YES;
}

// Shared tap handler: opens the tapped text post's embedded image the same
// way a normal image post opens its media, instead of confusingly opening
// the thread.
static id ApolloFeedIvar(id obj, const char *name);

@interface ApolloFeedHeroTapHandler : NSObject
@end

@implementation ApolloFeedHeroTapHandler
+ (instancetype)shared {
    static ApolloFeedHeroTapHandler *sShared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sShared = [[ApolloFeedHeroTapHandler alloc] init]; });
    return sShared;
}

- (void)heroTapped:(id)sender {
    @try {
        RDKLink *link = objc_getAssociatedObject(sender, &kApolloFeedHeroLinkKey);
        NSArray<NSDictionary *> *items = ApolloFeedViewerItemsForLink(link);
        ASDisplayNode *node = (ASDisplayNode *)sender;
        UIView *sourceView = [node isNodeLoaded] ? [node view] : nil;

        // Open the hero's image in Apollo's NATIVE media viewer via the
        // link-tap handler on the supernode chain (review feedback on the
        // PR: native viewer with its bottom toolbar and flick-to-dismiss
        // beats a custom gallery; the hero shows the first image, so that's
        // the one that opens).
        NSURL *url = [items.firstObject[@"url"] isKindOfClass:[NSURL class]] ? items.firstObject[@"url"] : nil;
        if (ApolloFeedRouteURLToNativeHandler(sender, url)) return;

        // Fallback: the tweak's own zoomable viewer.
        ApolloLog(@"[FeedThumb] hero tapped: no native handler, presenting %lu image(s) in fallback viewer",
                  (unsigned long)items.count);
        if (items.count > 0) {
            ApolloPresentImageChestItems(items, sourceView, 0);
        }
    } @catch (__unused NSException *e) {}
}

// Compact thumbnails we filled have no Apollo-wired tap action (Apollo only
// wires one for posts with media), so we attach this. Walks to the cell and
// replays its thumbnailTappedWithSender: — intercepted by the hook below,
// which points the link at the image so Apollo presents its native viewer.
// No-ops unless the post is still an eligible self post, so a reused
// thumbnail node on a media post can't double-fire Apollo's own action.
- (void)compactThumbTapped:(id)sender {
    @try {
        id target = sender;
        for (int hops = 0; target && hops < 24; hops++) {
            if ([target respondsToSelector:@selector(thumbnailTappedWithSender:)]) break;
            target = [target respondsToSelector:@selector(supernode)] ? [target supernode] : nil;
        }
        if (!target) {
            ApolloLog(@"[FeedThumb] compact thumb tap: no cell handler in chain");
            return;
        }
        RDKLink *link = ApolloFeedIvar(target, "link");
        if (!(link.selfPost && ApolloFeedThumbnailURLForLink(link))) return;
        ((void (*)(id, SEL, id))objc_msgSend)(target, @selector(thumbnailTappedWithSender:), sender);
    } @catch (__unused NSException *e) {}
}
@end

// Apply the URL to a thumbnail image node (idempotent — skips if already set).
static void ApolloFeedApplyThumbnailURL(id thumbNode, NSURL *url) {
    if (!thumbNode || !url) return;
    if (![thumbNode respondsToSelector:@selector(setURL:)]) return;

    ApolloFeedThumbImageNode *node = (ApolloFeedThumbImageNode *)thumbNode;
    NSURL *current = [thumbNode respondsToSelector:@selector(URL)] ? node.URL : nil;
    if ([current isEqual:url]) return;

    @try {
        if ([thumbNode respondsToSelector:@selector(setContentMode:)]) {
            node.contentMode = UIViewContentModeScaleAspectFill;
        }
        if ([thumbNode respondsToSelector:@selector(setClipsToBounds:)]) {
            node.clipsToBounds = YES;
        }
        node.URL = url;
    } @catch (__unused NSException *e) {}
}

// Remove naked direct-image URLs (e.g. https://preview.redd.it/xxxx.png?...) from
// a preview text node. Once the image is shown as a hero thumbnail, leaving its
// raw URL in the body preview is redundant clutter. Idempotent: re-stripping
// already-clean text is a no-op, so it's safe to call every layout pass.
static void ApolloFeedStripImageURLsFromTextNode(id textNodeOpaque) {
    if (!textNodeOpaque) return;
    ASTextNode *textNode = (ASTextNode *)textNodeOpaque;
    if (![textNode respondsToSelector:@selector(attributedText)]) return;
    if (![textNode respondsToSelector:@selector(setAttributedText:)]) return;

    NSAttributedString *attr = nil;
    @try { attr = textNode.attributedText; } @catch (__unused NSException *e) { return; }
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return;

    NSString *plain = attr.string;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A whitespace-or-start delimited http(s) URL ending in an image extension.
        re = [NSRegularExpression regularExpressionWithPattern:
              @"https?://\\S+\\.(?:png|jpe?g|webp|gif)(?:\\?\\S*)?"
                                                       options:NSRegularExpressionCaseInsensitive
                                                         error:NULL];
    });
    if (!re) return;

    NSArray<NSTextCheckingResult *> *matches =
        [re matchesInString:plain options:0 range:NSMakeRange(0, plain.length)];
    if (matches.count == 0) return;

    // Keep only matches that are direct image URLs on our allowlisted hosts.
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSTextCheckingResult *m in matches) {
        NSString *cand = [plain substringWithRange:m.range];
        if (ApolloFeedIsDirectImageURLString(cand)) {
            [ranges addObject:[NSValue valueWithRange:m.range]];
        }
    }
    if (ranges.count == 0) return;

    NSMutableAttributedString *mut = [attr mutableCopy];
    // Delete from the back so earlier ranges stay valid. Also swallow one
    // trailing newline/space so we don't leave a blank line behind.
    for (NSInteger i = (NSInteger)ranges.count - 1; i >= 0; i--) {
        NSRange r = ranges[(NSUInteger)i].rangeValue;
        NSUInteger end = r.location + r.length;
        while (end < mut.length) {
            unichar c = [mut.string characterAtIndex:end];
            if (c == '\n' || c == ' ' || c == '\t' || c == '\r') { r.length += 1; end += 1; }
            else break;
        }
        if (r.location + r.length <= mut.length) [mut deleteCharactersInRange:r];
    }

    // Trim leading whitespace/newlines left at the very start.
    while (mut.length > 0) {
        unichar c = [mut.string characterAtIndex:0];
        if (c == '\n' || c == ' ' || c == '\t' || c == '\r') {
            [mut deleteCharactersInRange:NSMakeRange(0, 1)];
        } else break;
    }

    if (![mut.string isEqualToString:plain]) {
        @try { textNode.attributedText = mut; } @catch (__unused NSException *e) {}
    }
}

// Weak registry of RichMediaNodes we injected a hero into, so we can re-apply
// our preview-text/link-card cleanup when the app returns to the foreground
// (Apollo rebuilds the preview text — re-adding the naked URL — without firing
// our layoutSpecThatFits: hook).
static NSHashTable *ApolloFeedInjectedNodes(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

// Read an ivar by name via the ObjC runtime (works outside %hook blocks).
static id ApolloFeedIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

// Hide the redundant link card and strip the naked image URL on a RichMediaNode.
//
// IMPORTANT: when called from inside layoutSpecThatFits: (a layout pass),
// triggerLayout MUST be NO. Calling setNeedsLayout during a layout pass
// re-dirties the node every pass and sends Texture into an infinite relayout
// loop (pegs the main thread -> scene-update watchdog kills the app). Only the
// foreground observer, which runs outside any layout pass, should pass YES.
static void ApolloFeedReapplyCleanup(id node, BOOL triggerLayout) {
    if (!node) return;
    @try {
        id linkButton = ApolloFeedIvar(node, "linkButtonNode");
        if (linkButton) {
            ASDisplayNode *lb = (ASDisplayNode *)linkButton;
            if ([lb respondsToSelector:@selector(setHidden:)]) lb.hidden = YES;
            if ([lb respondsToSelector:@selector(setAlpha:)]) lb.alpha = 0.0;
            id st = [lb respondsToSelector:@selector(style)] ? [lb style] : nil;
            if ([st respondsToSelector:@selector(setMaxSize:)]) {
                ((ApolloFeedLayoutStyle *)st).maxSize = CGSizeZero;
            }
            if ([st respondsToSelector:@selector(setPreferredSize:)]) {
                ((ApolloFeedLayoutStyle *)st).preferredSize = CGSizeZero;
            }
        }
        id previewText = ApolloFeedIvar(node, "selfPostPreviewNode");
        ApolloFeedStripImageURLsFromTextNode(previewText);
        if (triggerLayout && [node respondsToSelector:@selector(setNeedsLayout)]) {
            [(ASDisplayNode *)node setNeedsLayout];
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Compact feed cells

// CompactPostThumbnailNode renders the small leading square in compact list mode.
// For eligible self posts this square is an empty grey placeholder; we fill it.
%hook _TtC6Apollo24CompactPostThumbnailNode

- (id)layoutSpecThatFits:(struct ApolloFeedThumbSizeRange)constrainedSize {
    id spec = %orig;
    if (!sFeedTextPostThumbnails) return spec;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        NSURL *url = ApolloFeedThumbnailURLForLink(link);
        if (url) {
            id thumb = MSHookIvar<id>(self, "thumbnailNode");
            ApolloFeedApplyThumbnailURL(thumb, url);
            // Apollo wires the thumbnail's tap action only for posts with
            // media, so the squares we fill are inert — taps fell through to
            // the cell and opened the thread (review feedback on the PR).
            // Wire our own target once per wrapper; the handler re-checks
            // eligibility, so node reuse on media posts stays Apollo's.
            //
            // The wiring must run on the main queue, and `thumbnailNode` must
            // be RE-READ there: layoutSpecThatFits runs on Texture's
            // background layout threads, and a raw ivar pointer captured
            // across the async hop can dangle if the cell is torn down first
            // (crashed as doesNotRecognizeSelector on a reincarnated pointer).
            // Only the wrapper crosses the boundary, weakly.
            if (![objc_getAssociatedObject(self, &kApolloFeedCompactTapWiredKey) boolValue]) {
                objc_setAssociatedObject(self, &kApolloFeedCompactTapWiredKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                __weak ASDisplayNode *weakWrapper = (ASDisplayNode *)self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        ASDisplayNode *wrapper = weakWrapper;
                        if (!wrapper) return;
                        id thumbNode = ApolloFeedIvar(wrapper, "thumbnailNode");
                        if (![thumbNode respondsToSelector:@selector(addTarget:action:forControlEvents:)] ||
                            ![thumbNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
                            ApolloLog(@"[FeedThumb] compact wiring skipped: thumb=%@ lacks control surface",
                                      NSStringFromClass([thumbNode class]));
                            return;
                        }
                        // Apollo leaves the whole thumbnail chain inert for
                        // media-less posts; touches need every ancestor enabled.
                        wrapper.userInteractionEnabled = YES;
                        [(ASNetworkImageNode *)thumbNode setUserInteractionEnabled:YES];
                        [(ASNetworkImageNode *)thumbNode addTarget:[ApolloFeedHeroTapHandler shared]
                                                            action:@selector(compactThumbTapped:)
                                                  forControlEvents:ApolloFeedControlEventTouchUpInside];
                        ApolloLog(@"[FeedThumb] compact tap target wired (thumb=%@)", NSStringFromClass([thumbNode class]));
                    } @catch (NSException *e) {
                        ApolloLog(@"[FeedThumb] compact wiring failed: %@", e.reason);
                    }
                });
            }
        }
    } @catch (__unused NSException *e) {}
    return spec;
}

%end

// Compact cells: Apollo only wires a thumbnail tap action when the post has
// media, so for our filled-in text post thumbnails the tap fell through to
// the cell and opened the thread (review feedback on the PR). Intercept the
// tap and replay Apollo's own handler with the link temporarily pointed at
// the embedded image: Apollo then presents its native media viewer — bottom
// toolbar wired to the post's votes/comments, flick-to-dismiss — exactly as
// if this were an image post. URL and selfPost are restored immediately
// after the synchronous presentation.
%hook _TtC6Apollo19CompactPostCellNode

- (void)thumbnailTappedWithSender:(id)sender {
    if (sFeedTextPostThumbnails) {
        @try {
            RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
            if (link && link.selfPost && ApolloFeedThumbnailURLForLink(link)) {
                NSArray<NSDictionary *> *items = ApolloFeedViewerItemsForLink(link);
                NSURL *imageURL = [items.firstObject[@"url"] isKindOfClass:[NSURL class]] ? items.firstObject[@"url"] : nil;
                if (imageURL) {
                    ApolloLog(@"[FeedThumb] compact thumbnail tapped: replaying native handler with %@", imageURL.host);
                    NSURL *originalURL = link.URL;
                    BOOL originalSelfPost = link.selfPost;
                    link.URL = imageURL;
                    link.selfPost = NO;
                    @try {
                        %orig;
                    } @finally {
                        link.URL = originalURL;
                        link.selfPost = originalSelfPost;
                    }
                    return;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    %orig;
}

%end

#pragma mark - Large feed cells

// RichMediaNode renders the large-mode media area. For eligible self/text posts
// it normally shows only the selftext preview + a link button, with no thumbnail
// node at all (thumbnailNode is nil). We inject our own ASNetworkImageNode as a
// hero image above Apollo's original content.
%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloFeedThumbSizeRange)constrainedSize {
    id origSpec = %orig;
    if (!sFeedTextPostThumbnails) {
        // Toggled off mid-session: a previously injected hero would otherwise
        // keep its last frame even though it left the layout spec.
        ASDisplayNode *staleHero = objc_getAssociatedObject(self, &kApolloFeedHeroNodeKey);
        if (staleHero) staleHero.hidden = YES;
        // Even without a thumbnail, a naked image URL leading the preview
        // text is noise — show the post's actual text, like a normal text
        // post. (Link card stays native.)
        @try {
            RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
            if (link && link.selfPost && ApolloFeedThumbnailURLForLink(link)) {
                ApolloFeedStripImageURLsFromTextNode(ApolloFeedIvar(self, "selfPostPreviewNode"));
                [ApolloFeedInjectedNodes() addObject:self];
            }
        } @catch (__unused NSException *e) {}
        return origSpec;
    }

    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!link || !link.selfPost) return origSpec;

        NSURL *url = ApolloFeedThumbnailURLForLink(link);
        if (!url) return origSpec;

        // Only inject when Apollo built no native media area for this post —
        // otherwise normal image/video/album posts would get a duplicate hero.
        id thumb = MSHookIvar<id>(self, "thumbnailNode");
        id videoNode = MSHookIvar<id>(self, "videoNode");
        id albumNode = MSHookIvar<id>(self, "albumThumbnailsNode");
        if (thumb || videoNode || albumNode) {
            return origSpec;
        }

        // Inject the hero at its known aspect-ratio size on this very first
        // layout pass. The ratio is resolved synchronously up front from the
        // post's media metadata (see kApolloFeedThumbRatioKey), so the cell is
        // its final height immediately — we never grow the cell after the table
        // has settled. This is critical: any post-settle height change here
        // would retrigger PostsViewController.viewDidLayoutSubviews and churn
        // the subreddit banner header, which is what made the banner placeholder
        // skip and the banner pop in after the feed.

        // The hero now shows the embedded image, so hide the redundant bare link
        // card and strip the raw image URL from the preview text. We are inside a
        // layout pass here, so do NOT trigger a relayout (would loop the main
        // thread and trip the watchdog).
        ApolloFeedReapplyCleanup(self, NO);
        // Remember this node so we can re-apply the cleanup on foreground (Apollo
        // rebuilds the preview text without re-running this layout pass).
        [ApolloFeedInjectedNodes() addObject:self];

        // Reuse a single hero node per RichMediaNode across layout passes.
        ASNetworkImageNode *hero =
            (ASNetworkImageNode *)objc_getAssociatedObject(self, &kApolloFeedHeroNodeKey);
        if (!hero) {
            Class imgCls = objc_getClass("ASNetworkImageNode");
            if (!imgCls) return origSpec;
            hero = [[imgCls alloc] init];
            @try {
                hero.contentMode = UIViewContentModeScaleAspectFill;
                hero.clipsToBounds = YES;
                hero.cornerRadius = 10.0;
                // Keep the reserved hero area transparent so it blends with the
                // post card (any theme) instead of flashing a bright/grey box
                // while the image downloads.
                hero.backgroundColor = [UIColor clearColor];
                if ([hero respondsToSelector:@selector(setPlaceholderEnabled:)]) {
                    hero.placeholderEnabled = YES;
                }
                // Faint translucent placeholder (theme-agnostic) rather than a
                // hard light box, matching Apollo's own image-node placeholders.
                if ([hero respondsToSelector:@selector(setPlaceholderColor:)]) {
                    hero.placeholderColor = [UIColor colorWithWhite:1.0 alpha:0.04];
                }
                // Cross-fade the downloaded image in instead of popping.
                if ([hero respondsToSelector:@selector(setPlaceholderFadeDuration:)]) {
                    hero.placeholderFadeDuration = 0.3;
                }
                // Explicit opacity fade-in once the image lands, so the fade is
                // perceptible even on cache hits (placeholder alone is nearly
                // transparent and wouldn't read as a fade).
                if ([hero respondsToSelector:@selector(setDelegate:)]) {
                    hero.delegate = [ApolloFeedHeroFadeDelegate shared];
                }
                // Tapping the hero opens the embedded image(s) fullscreen,
                // matching what a thumbnail tap does on a real image post
                // (issue #419). Taps elsewhere still open the thread.
                if ([hero respondsToSelector:@selector(addTarget:action:forControlEvents:)]) {
                    hero.userInteractionEnabled = YES;
                    [hero addTarget:[ApolloFeedHeroTapHandler shared]
                             action:@selector(heroTapped:)
                   forControlEvents:ApolloFeedControlEventTouchUpInside];
                } else {
                    ApolloLog(@"[FeedThumb] hero node does not support target-action; tap-to-open disabled");
                }
            } @catch (__unused NSException *e) {}
            [(ASDisplayNode *)self addSubnode:hero];
            objc_setAssociatedObject(self, &kApolloFeedHeroNodeKey, hero,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![hero.URL isEqual:url]) hero.URL = url;
        hero.hidden = NO;
        // Cells are reused across links — keep the tap handler's link current.
        objc_setAssociatedObject(hero, &kApolloFeedHeroLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Size the hero via an aspect ratio (height/width) layout spec.
        CGFloat ratio = 0.56;
        NSNumber *r = objc_getAssociatedObject(link, &kApolloFeedThumbRatioKey);
        if ([r isKindOfClass:[NSNumber class]]) ratio = r.doubleValue;

        Class ratioCls = objc_getClass("ASRatioLayoutSpec");
        Class stackCls = objc_getClass("ASStackLayoutSpec");
        if (!ratioCls || !stackCls || !origSpec) {
            return origSpec;
        }

        id heroSpec = [ratioCls ratioLayoutSpecWithRatio:ratio child:hero];

        // RichMediaNode spans the cell edge-to-edge (Apollo's image posts are
        // intentionally full-bleed), but a rounded-corner thumbnail looks
        // clipped flush against the screen edge. Inset it to Apollo's standard
        // content margin so it lines up with the title/body text (review
        // feedback on #426).
        Class insetCls = objc_getClass("ASInsetLayoutSpec");
        if (insetCls) {
            id padded = [insetCls insetLayoutSpecWithInsets:UIEdgeInsetsMake(0, kApolloFeedHeroSideInset, 0, kApolloFeedHeroSideInset)
                                                      child:heroSpec];
            if (padded) heroSpec = padded;
        }

        id stacked = [stackCls stackLayoutSpecWithDirection:ApolloFeedStackDirectionVertical
                                                    spacing:8.0
                                             justifyContent:ApolloFeedStackJustifyStart
                                                 alignItems:ApolloFeedStackAlignStretch
                                                   children:@[ heroSpec, origSpec ]];
        return stacked ?: origSpec;
    } @catch (__unused NSException *e) {}
    return origSpec;
}

%end

#pragma mark - ctor

%ctor {
    ApolloLog(@"[FeedThumb] ApolloFeedTextPostThumbnails loaded enabled=%d", (int)sFeedTextPostThumbnails);

    // When the app returns to the foreground, Apollo rebuilds the self-post
    // preview text (re-adding the naked image URL) without re-running our
    // layoutSpecThatFits: hook. Re-apply our cleanup on the nodes we injected
    // into, with a few staggered passes to beat Apollo's text rebuild.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        for (NSNumber *delay in @[ @0.0, @0.2, @0.6 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    for (id node in ApolloFeedInjectedNodes().allObjects) {
                        if (sFeedTextPostThumbnails) {
                            // Full cleanup: hidden link card + stripped URL.
                            ApolloFeedReapplyCleanup(node, YES);
                        } else {
                            // Toggle off: only keep the preview text clean.
                            ApolloFeedStripImageURLsFromTextNode(ApolloFeedIvar(node, "selfPostPreviewNode"));
                        }
                    }
                } @catch (__unused NSException *e) {}
            });
        }
    }];
}
