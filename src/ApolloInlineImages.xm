// ApolloInlineImages.xm
//
// Renders image URLs inside Apollo's selftext / comment markdown bodies as
// actual inline images, replacing the URL text in-place. Tap opens
// MediaViewer (via Apollo's tappedLinkAttribute path); long-press shows
// Copy Link / Share / Open in Safari (UIContextMenuInteraction wins over
// Apollo's cell-level menu since it's installed on the deeper view).
//

#import "ApolloCommon.h"
#import "ApolloImageChestResolver.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - Minimal Texture forward declarations
// We don't import AsyncDisplayKit headers (the build doesn't have them on the
// include path). Just declare the methods/classes we need; the runtime resolves
// to the real Apollo-bundled implementations.

typedef NS_OPTIONS(NSUInteger, ApolloASControlNodeEvent) {
    ApolloASControlNodeEventTouchUpInside = 1 << 4,
};

typedef NS_ENUM(unsigned char, ApolloASStackLayoutDirection) {
    ApolloASStackLayoutDirectionVertical = 0,
    ApolloASStackLayoutDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutJustifyContent) {
    ApolloASStackLayoutJustifyContentStart = 0,
    ApolloASStackLayoutJustifyContentCenter = 1,
    ApolloASStackLayoutJustifyContentEnd = 2,
    ApolloASStackLayoutJustifyContentSpaceBetween = 3,
    ApolloASStackLayoutJustifyContentSpaceAround = 4,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutAlignItems) {
    ApolloASStackLayoutAlignItemsStart = 0,
    ApolloASStackLayoutAlignItemsEnd = 1,
    ApolloASStackLayoutAlignItemsCenter = 2,
    ApolloASStackLayoutAlignItemsStretch = 3,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutAlignSelf) {
    ApolloASStackLayoutAlignSelfAuto = 0,
    ApolloASStackLayoutAlignSelfStart = 1,
    ApolloASStackLayoutAlignSelfEnd = 2,
    ApolloASStackLayoutAlignSelfCenter = 3,
    ApolloASStackLayoutAlignSelfStretch = 4,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASRatioLayoutSpec;
@class ASInsetLayoutSpec;
@class ASNetworkImageNode;
@class ASTextNode;
@class ASDisplayNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
- (id)style;
- (UIView *)view;
- (BOOL)isNodeLoaded;
- (void)onDidLoad:(void(^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nullable, weak) id delegate;
@property (copy) NSArray<NSString *> *linkAttributeNames;
@property (nonatomic) BOOL passthroughNonlinkTouches;
@property (nonatomic) BOOL longPressCancelsTouches;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nullable, nonatomic, strong) UIImage *image;
@property (nullable, weak) id delegate;
@property (nonatomic) BOOL shouldRenderProgressImages;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL placeholderEnabled;
@property (nonatomic, copy) UIColor *placeholderColor;
@property (nonatomic) CGFloat placeholderFadeDuration;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) CGColorRef borderColor;
@property (nullable) id animatedImage;
- (void)clearImage;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(ApolloASControlNodeEvent)events;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloASStackLayoutDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloASStackLayoutJustifyContent justifyContent;
@property (nonatomic) ApolloASStackLayoutAlignItems alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloASStackLayoutDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloASStackLayoutJustifyContent)justifyContent
                                  alignItems:(ApolloASStackLayoutAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

// ASSizeRange (named CDStruct_90e057aa in Apollo's class-dumped headers).
struct CDStruct_90e057aa { CGSize min; CGSize max; };

// MARK: - Associated-object keys

static char kApolloDecompositionMapKey;        // NSDictionary<NSValue (non-retained orig text node ptr), NSArray<id leaf>>
static char kApolloCachedOrigChildrenKey;      // NSArray (held strongly so element pointers stay valid for compare)
static char kApolloProvisionalDecompKey;       // NSNumber(BOOL): decomposition built while comment mediaMetadata was unreachable (don't cache)
static char kApolloImageNodesByURLKey;         // NSMutableDictionary<NSString URL, ASNetworkImageNode> per-MarkdownNode reuse cache
static char kApolloImageCacheKey;              // NSString stable cache key (set even before deferred image URLs resolve)
static char kApolloImageURLKey;                // NSURL on the imageNode AND mirrored on the imageNode's view
static char kApolloOriginalImageURLKey;        // NSURL for tap/long-press when different from the loaded URL (e.g. album URL)
static char kApolloHostMarkdownNodeKey;        // weak ref (assign association) to the host MarkdownNode
static char kApolloAspectRatioKey;             // NSNumber height/width — NIL if unknown (no URL params yet, no DIDLOAD yet)
static char kApolloLongPressInstalledKey;      // NSNumber BOOL — gate for one-shot UIContextMenuInteraction install
static char kApolloPlayOverlayViewKey;         // ApolloPlayOverlayContainer (play button OR pause badge), also used as install gate
static char kApolloInlineAnimatedGIFKey;       // NSNumber BOOL — node loaded an animated GIF
static char kApolloInlineGIFAnimatedImageKey;  // id — retained animated image for tap-to-play restore
static char kApolloInlineGIFCoverImageKey;     // UIImage — first-frame cover for static pause + refresh
static char kApolloInlineGIFUserForcedPlayKey; // NSNumber BOOL — user tapped play on paused GIF
static char kApolloInlineGIFPendingPolicyBlocksKey; // NSMutableArray<dispatch_block_t>
static char kApolloInlineGIFGenerationKey;     // NSNumber — bumped on clear/reuse to invalidate async GIF policy blocks
static char kApolloInlineGIFReloadInFlightKey; // NSNumber BOOL — internal URL/image reset in progress (settings-refresh reload, pause cover swap): suppress ClearState from the reset round trip
static char kApolloInlineGIFOverlayReassertKey; // NSNumber BOOL — a play-overlay reassert sequence is pending for this GIF node
static char kApolloStackedCardSyncerKey;       // ApolloStackedCardSyncer — keeps the multi-image card peeking behind imageNode
static char kApolloImageChestItemsKey;         // NSArray<NSDictionary *> direct ImageChest CDN image entries for album pager

// kApolloHostMarkdownNodeKey is an OBJC_ASSOCIATION_ASSIGN (unsafe unretained)
// reference to the host MarkdownNode. The host can be deallocated before the
// image node (e.g. during comments table teardown), leaving the association
// slot pointing at freed memory. Reading it as an `id` lets ARC retain the
// result, which crashes in objc_retain on the dangling pointer. Bridge-cast to
// a raw void* so ARC performs no retain/release; we only ever need to know
// whether the node is an inline-hosted image node, not to message the host.
static inline BOOL ApolloImageNodeHasInlineHost(id node) {
    if (!node) return NO;
    return ((__bridge void *)objc_getAssociatedObject(node, &kApolloHostMarkdownNodeKey)) != NULL;
}

static void ApolloApplyInlineGIFPlaybackPolicyWithCover(ASNetworkImageNode *imageNode, UIImage *cover, NSUInteger retryIndex);
static void ApolloStartInlineGIFPlayback(ASNetworkImageNode *imageNode);
static void ApolloStopInlineGIFPlayback(ASNetworkImageNode *imageNode);
static BOOL ApolloResumeInlineGIFPlaybackIfPossible(ASNetworkImageNode *imageNode);
static void ApolloClearInlineGIFNodeState(ASNetworkImageNode *node);
static NSUInteger ApolloInlineGIFGenerationForNode(id node);
static NSUInteger ApolloInlineGIFBumpGeneration(id node);
static BOOL ApolloInlineGIFGenerationMatches(id node, NSUInteger generation);
static BOOL ApolloInlineGIFAnimatedImageArgumentIsUsable(id animatedImage);
static void ApolloCancelInlineGIFPendingPolicyBlocks(id node);
static void ApolloClearInlineGIFCoverImageReadyCallback(id anim);
static void ApolloTrackInlineGIFPendingPolicyBlock(ASDisplayNode *node, dispatch_block_t block);
static void ApolloInstallPlayOverlayOnView(UIView *v, ASDisplayNode *node);
static void ApolloRemovePlayOverlayFromNode(ASDisplayNode *node);
static void ApolloUpdateInlineGIFOverlayForNode(ASDisplayNode *node);
static void ApolloSchedulePlayOverlayReassert(ASNetworkImageNode *imageNode, NSUInteger attempt);
static NSDictionary *ApolloMediaMetadataForHost(ASDisplayNode *hostMarkdownNode);

// MARK: - Class lookups (cached)

static Class ApolloASStackLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASStackLayoutSpec"); });
    return c;
}
static Class ApolloASRatioLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASRatioLayoutSpec"); });
    return c;
}
static Class ApolloASInsetLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASInsetLayoutSpec"); });
    return c;
}
static Class ApolloASTextNodeClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASTextNode"); });
    return c;
}
static Class ApolloASNetworkImageNodeClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASNetworkImageNode"); });
    return c;
}
static NSMutableSet<NSString *> *ApolloInlineSuppressionKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [NSMutableSet set]; });
    return keys;
}

static NSString *ApolloDecodedAbsoluteString(NSURL *url) {
    NSString *abs = [url absoluteString];
    if (![abs isKindOfClass:[NSString class]] || abs.length == 0) return nil;
    return [abs stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

static NSString *ApolloInlineSuppressionPathKey(NSURL *url) {
    NSString *host = [[url host] lowercaseString];
    NSString *path = [url path];
    if (host.length == 0 || path.length == 0) return nil;
    return [NSString stringWithFormat:@"path:%@%@", host, path];
}

static void ApolloRegisterInlineSuppressionURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSString *abs = ApolloDecodedAbsoluteString(url);
    NSString *pathKey = ApolloInlineSuppressionPathKey(url);
    @synchronized (ApolloInlineSuppressionKeys()) {
        NSMutableSet<NSString *> *keys = ApolloInlineSuppressionKeys();
        if (keys.count > 512) [keys removeAllObjects];
        if (abs.length > 0) [keys addObject:[@"abs:" stringByAppendingString:abs]];
        if (pathKey.length > 0) [keys addObject:pathKey];
    }
}

static BOOL ApolloInlineSuppressionContainsURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *abs = ApolloDecodedAbsoluteString(url);
    NSString *pathKey = ApolloInlineSuppressionPathKey(url);
    @synchronized (ApolloInlineSuppressionKeys()) {
        NSMutableSet<NSString *> *keys = ApolloInlineSuppressionKeys();
        if (abs.length > 0 && [keys containsObject:[@"abs:" stringByAppendingString:abs]]) return YES;
        if (pathKey.length > 0 && [keys containsObject:pathKey]) return YES;
    }
    return NO;
}

// MARK: - Image URL classification & normalization

// YES for bare Imgur share URLs (imgur.com/<id>) — a single alphanumeric
// path component with no extension. Excludes albums, galleries, tags.
static BOOL ApolloIsImgurShareURL(NSURL *url) {
    NSString *host = [[url host] lowercaseString];
    if (![host isEqualToString:@"imgur.com"] && ![host isEqualToString:@"www.imgur.com"]) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSString *path = url.path ?: @"";
    if ([path hasPrefix:@"/a/"] || [path hasPrefix:@"/gallery/"] || [path hasPrefix:@"/t/"]) return NO;
    NSString *imgurID = path.length > 1 ? [path substringFromIndex:1] : @"";
    if (imgurID.length == 0) return NO;
    if ([imgurID rangeOfString:@"/"].location != NSNotFound) return NO;
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [imgurID rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

// Imgur albums (imgur.com/a/<id>) and galleries (imgur.com/gallery/<id>)
// require an API roundtrip to resolve to a renderable image URL. We
// classify them as inline-renderable so they hit the inline pipeline,
// then defer URL assignment until the API resolution completes.
static NSString *ApolloImgurPathID(NSURL *url, NSString *prefix) {
    NSString *host = [[url host] lowercaseString];
    if (![host isEqualToString:@"imgur.com"] && ![host isEqualToString:@"www.imgur.com"]) return nil;
    if (url.pathExtension.length > 0) return nil;
    NSString *path = [url.path stringByRemovingPercentEncoding] ?: @"";
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 2 || ![[clean[0] lowercaseString] isEqualToString:prefix]) return nil;
    NSString *imgurID = clean[1];
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [imgurID rangeOfCharacterFromSet:disallowed].location == NSNotFound ? imgurID : nil;
}
static NSString *ApolloImgurAlbumID(NSURL *url) { return ApolloImgurPathID(url, @"a"); }
static NSString *ApolloImgurGalleryID(NSURL *url) { return ApolloImgurPathID(url, @"gallery"); }
static BOOL ApolloIsImgurAlbumOrGalleryURL(NSURL *url) {
    return ApolloImgurAlbumID(url).length > 0 || ApolloImgurGalleryID(url).length > 0;
}

static NSString *ApolloImgurResolutionCacheKey(NSURL *url) {
    NSString *albumID = ApolloImgurAlbumID(url);
    if (albumID.length > 0) return [@"album:" stringByAppendingString:albumID];
    NSString *galleryID = ApolloImgurGalleryID(url);
    if (galleryID.length > 0) return [@"gallery:" stringByAppendingString:galleryID];
    return nil;
}

static NSObject *ApolloImgurResolverLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSMutableDictionary<NSString *, id> *ApolloImgurResolverCache(void) {
    static NSMutableDictionary<NSString *, id> *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloImgurResolverPending(void) {
    static NSMutableDictionary<NSString *, NSMutableArray *> *pending; static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}

// Build a renderable i.imgur.com URL from an Imgur API image dict.
// Rewrites .gifv/.mp4 to .gif so PINRemoteImage's image pipeline can
// decode it as an animated GIF rather than getting MP4 bytes.
static NSURL *ApolloImgurDisplayURLFromImageDictionary(NSDictionary *image) {
    NSString *link = [image[@"link"] isKindOfClass:[NSString class]] ? image[@"link"] : nil;
    NSString *imageID = [image[@"id"] isKindOfClass:[NSString class]] ? image[@"id"] : nil;
    BOOL animated = [image[@"animated"] respondsToSelector:@selector(boolValue)] && [image[@"animated"] boolValue];
    NSString *type = [image[@"type"] isKindOfClass:[NSString class]] ? [image[@"type"] lowercaseString] : @"";

    if (link.length == 0 && imageID.length > 0) {
        NSString *ext = animated || [type containsString:@"gif"] ? @"gif" : ([type containsString:@"png"] ? @"png" : @"jpg");
        link = [NSString stringWithFormat:@"https://i.imgur.com/%@.%@", imageID, ext];
    }
    if (link.length == 0) return nil;

    NSString *lowerLink = [link lowercaseString];
    if ([lowerLink hasSuffix:@".gifv"] || [lowerLink hasSuffix:@".mp4"]) {
        link = [[link stringByDeletingPathExtension] stringByAppendingPathExtension:@"gif"];
    }
    link = [link stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:link];
}

static NSDictionary *ApolloImgurResultFromImageDictionary(NSDictionary *image) {
    if (![image isKindOfClass:[NSDictionary class]]) return nil;
    NSURL *displayURL = ApolloImgurDisplayURLFromImageDictionary(image);
    if (![displayURL isKindOfClass:[NSURL class]]) return nil;

    NSMutableDictionary *result = [@{ @"url": displayURL } mutableCopy];
    NSNumber *width = [image[@"width"] respondsToSelector:@selector(doubleValue)] ? image[@"width"] : nil;
    NSNumber *height = [image[@"height"] respondsToSelector:@selector(doubleValue)] ? image[@"height"] : nil;
    if (width.doubleValue > 0 && height.doubleValue > 0) {
        result[@"width"] = width;
        result[@"height"] = height;
    }
    return result;
}

// Extract a display image from an Imgur API response payload (data field).
// Handles three shapes: bare image dict, album/gallery dict with images[],
// and image-array directly. For albums, prefers the cover image.
static NSDictionary *ApolloImgurResultFromAPIData(id data) {
    if ([data isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)data) {
            NSDictionary *result = ApolloImgurResultFromImageDictionary(item);
            if (result) return result;
        }
        return nil;
    }
    if (![data isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)data;
    NSArray *images = [dict[@"images"] isKindOfClass:[NSArray class]] ? dict[@"images"] : nil;
    if (images.count > 0) {
        NSDictionary *picked = nil;
        NSString *coverID = [dict[@"cover"] isKindOfClass:[NSString class]] ? dict[@"cover"] : nil;
        if (coverID.length > 0) {
            for (id item in images) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *imageID = [item[@"id"] isKindOfClass:[NSString class]] ? item[@"id"] : nil;
                if ([imageID isEqualToString:coverID]) {
                    picked = ApolloImgurResultFromImageDictionary(item);
                    if (picked) break;
                }
            }
        }
        if (!picked) {
            for (id item in images) {
                picked = ApolloImgurResultFromImageDictionary(item);
                if (picked) break;
            }
        }
        if (!picked) return nil;
        NSMutableDictionary *out = [picked mutableCopy];
        out[@"count"] = @(images.count);
        return out;
    }
    return ApolloImgurResultFromImageDictionary(dict);
}

// Galleries can be albums, single images, or "topic" wrappers — try each
// shape until one parses. Albums have a fixed endpoint.
static NSArray<NSURL *> *ApolloImgurAPIEndpointsForURL(NSURL *url) {
    NSString *albumID = ApolloImgurAlbumID(url);
    if (albumID.length > 0) {
        return @[[NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:albumID]]];
    }
    NSString *galleryID = ApolloImgurGalleryID(url);
    if (galleryID.length > 0) {
        return @[
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/album/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/image/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:galleryID]],
        ];
    }
    return @[];
}

static void ApolloDeliverImgurResolution(NSString *cacheKey, NSDictionary *result) {
    NSArray *callbacks = nil;
    @synchronized (ApolloImgurResolverLock()) {
        ApolloImgurResolverCache()[cacheKey] = result ?: (id)[NSNull null];
        callbacks = [ApolloImgurResolverPending()[cacheKey] copy];
        [ApolloImgurResolverPending() removeObjectForKey:cacheKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^callback)(NSDictionary *) in callbacks) callback(result);
    });
}

static void ApolloFetchImgurEndpointAtIndex(NSArray<NSURL *> *endpoints, NSUInteger index, NSString *cacheKey) {
    if (index >= endpoints.count) {
        ApolloLog(@"[InlineImages] Imgur resolve FAIL key=%@", cacheKey);
        ApolloDeliverImgurResolution(cacheKey, nil);
        return;
    }
    NSURL *endpoint = endpoints[index];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:8.0];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (sImgurClientId.length > 0) {
        [request setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[InlineImages] Imgur endpoint FAIL key=%@ index=%lu status=%ld err=%@",
                      cacheKey, (unsigned long)index, (long)status, error.localizedDescription ?: @"nil");
            ApolloFetchImgurEndpointAtIndex(endpoints, index + 1, cacheKey);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id payload = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSDictionary *result = ApolloImgurResultFromAPIData(payload);
        if (!result) {
            ApolloFetchImgurEndpointAtIndex(endpoints, index + 1, cacheKey);
            return;
        }
        ApolloLog(@"[InlineImages] Imgur resolved key=%@ url=%@ size=%@x%@",
                  cacheKey, result[@"url"], result[@"width"] ?: @"?", result[@"height"] ?: @"?");
        ApolloDeliverImgurResolution(cacheKey, result);
    }];
    [task resume];
}

static NSDictionary *ApolloCachedImgurResolution(NSURL *url) {
    NSString *cacheKey = ApolloImgurResolutionCacheKey(url);
    if (cacheKey.length == 0) return nil;
    @synchronized (ApolloImgurResolverLock()) {
        id cached = ApolloImgurResolverCache()[cacheKey];
        return [cached isKindOfClass:[NSDictionary class]] ? cached : nil;
    }
}

// Resolve an Imgur album/gallery URL to a renderable image. Coalesces
// concurrent calls for the same album/gallery ID. Negative results are
// cached (NSNull) so failed lookups don't retry per-cell.
static void ApolloResolveImgurURL(NSURL *url, void (^completion)(NSDictionary *result)) {
    NSString *cacheKey = ApolloImgurResolutionCacheKey(url);
    NSArray<NSURL *> *endpoints = ApolloImgurAPIEndpointsForURL(url);
    if (cacheKey.length == 0 || endpoints.count == 0) {
        if (completion) completion(nil);
        return;
    }
    void (^callback)(NSDictionary *) = [completion copy];
    BOOL shouldStartFetch = NO;
    NSDictionary *cachedResult = nil;
    BOOL hasCachedFailure = NO;

    @synchronized (ApolloImgurResolverLock()) {
        id cached = ApolloImgurResolverCache()[cacheKey];
        if ([cached isKindOfClass:[NSDictionary class]]) {
            cachedResult = cached;
        } else if (cached == [NSNull null]) {
            hasCachedFailure = YES;
        } else {
            NSMutableArray *pending = ApolloImgurResolverPending()[cacheKey];
            if (pending) {
                if (callback) [pending addObject:callback];
            } else {
                ApolloImgurResolverPending()[cacheKey] = callback ? [NSMutableArray arrayWithObject:callback] : [NSMutableArray array];
                shouldStartFetch = YES;
            }
        }
    }
    if (cachedResult || hasCachedFailure) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(cachedResult); });
        return;
    }
    if (shouldStartFetch) {
        ApolloLog(@"[InlineImages] Imgur resolve START key=%@ endpoints=%lu", cacheKey, (unsigned long)endpoints.count);
        ApolloFetchImgurEndpointAtIndex(endpoints, 0, cacheKey);
    }
}

// Image Chest album metadata is resolved by ApolloImageChestResolver.
static BOOL ApolloIsInlineRenderableImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    // Imgur share URLs (imgur.com/<id>) — extensionless; normalizer
    // canonicalizes to i.imgur.com/<id>.jpeg.
    // Imgur album/gallery URLs (imgur.com/a/<id>, imgur.com/gallery/<id>) —
    // resolved asynchronously via Imgur API; URL is deferred until
    // resolution completes.
    if (ApolloIsImgurShareURL(url) || ApolloIsImgurAlbumOrGalleryURL(url) || ApolloImageChestIsPostURL(url)) return YES;

    NSString *ext = [[[url path] pathExtension] lowercaseString];
    static NSSet *imageExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageExts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];
    });
    if (![imageExts containsObject:ext]) return NO;

    // Skip Reddit's pseudo-MP4 GIFs — the path ends in .gif but the query
    // says format=mp4, so the bytes returned are MP4 video, not a GIF.
    // PINRemoteImage can't decode them as image or animated image, leaving
    // an empty grey container. Let the LinkButtonNode preview handle these.
    NSString *q = [[url query] lowercaseString];
    if ([q containsString:@"format=mp4"]) return NO;

    // Allowlist of trusted parent domains. A host matches if it equals
    // a parent domain or is a subdomain of one. Curated to cover common
    // image hosts in Reddit comments while keeping random tracker pixels
    // and arbitrary image-extensioned URLs out (privacy + bandwidth).
    static NSArray<NSString *> *allowedParentDomains;
    static dispatch_once_t hostsOnce;
    dispatch_once(&hostsOnce, ^{
        allowedParentDomains = @[
            @"redd.it",
            @"imgur.com",
            @"giphy.com",
            @"tenor.com",
            @"redgifs.com",
            @"twimg.com",
            @"discordapp.com",
            @"discordapp.net",
            @"imgchest.com",
        ];
    });
    for (NSString *parent in allowedParentDomains) {
        if ([host isEqualToString:parent]) return YES;
        if ([host hasSuffix:[@"." stringByAppendingString:parent]]) return YES;
    }
    return NO;
}

static BOOL ApolloIsInlineRenderableVideoURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    // Two URL forms we know how to derive a poster for:
    //   1. Reddit pseudo-MP4 GIFs (preview.redd.it/*.gif?format=mp4) →
    //      poster from mediaMetadata[id].p[] signed thumbnail.
    //   2. Reddit hosted video permalinks
    //      (reddit.com/link/<post>/video/<asset>/player) → poster from
    //      DASH manifest + AVAssetImageGenerator frame extraction.
    NSString *ext = [[url path] pathExtension].lowercaseString ?: @"";
    NSString *q = [[url query] lowercaseString] ?: @"";
    BOOL isRedditPreview = [host isEqualToString:@"preview.redd.it"]
                          || [host isEqualToString:@"external-preview.redd.it"]
                          || [host hasSuffix:@".redd.it"];
    if (isRedditPreview && [ext isEqualToString:@"gif"] && [q containsString:@"format=mp4"]) return YES;

    NSString *path = [[url path] lowercaseString] ?: @"";
    BOOL isReddit = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (isReddit && [path hasPrefix:@"/link/"] && [path containsString:@"/video/"]
        && [path hasSuffix:@"/player"]) return YES;

    return NO;
}

// Returns the mediaMetadata key for a given video URL — either the image
// id (pseudo-MP4 GIFs) or the asset id (player URLs). Both forms key the
// metadata dict by id.
static NSString *ApolloMediaMetadataIDFromVideoURL(NSURL *videoURL) {
    NSString *host = [[videoURL host] lowercaseString] ?: @"";
    NSString *path = [videoURL path] ?: @"";
    if ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        // /link/<post>/video/<asset>/player → asset
        NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
        if (comps.count >= 6 && [comps[1] isEqualToString:@"link"]
            && [comps[3] isEqualToString:@"video"]) {
            return comps[4];
        }
        return nil;
    }
    // preview.redd.it/<id>.gif → id
    return [[videoURL lastPathComponent] stringByDeletingPathExtension];
}

// Find mediaMetadata for the hosting comment/post by walking up the
// supernode chain looking for a node with a `comment` or `link` ivar.
// Apollo's CommentCellNode holds the RDKComment; CommentsHeaderCellNode
// holds the RDKLink. Both models carry mediaMetadata for native uploads.
static NSDictionary *ApolloMediaMetadataForHost(ASDisplayNode *hostMarkdownNode) {
    for (ASDisplayNode *n = hostMarkdownNode; n; n = n.supernode) {
        for (const char *ivarName : (const char *[]){"comment", "link"}) {
            Ivar ivar = class_getInstanceVariable([n class], ivarName);
            if (!ivar) continue;
            id model = nil;
            @try { model = object_getIvar(n, ivar); } @catch (__unused NSException *e) {}
            if (!model || ![model respondsToSelector:@selector(mediaMetadata)]) continue;
            id md = [model performSelector:@selector(mediaMetadata)];
            if ([md isKindOfClass:[NSDictionary class]]) return md;
        }
    }
    return nil;
}

// Find the mediaMetadata entry for a given video URL. Tries direct id
// lookup first; falls back to scanning s.gif/s.mp4 URLs for a match
// (giphy entries have keys like "giphy|<id>" that don't match the
// preview.redd.it filename in the video URL).
static NSDictionary *ApolloMediaMetadataEntryForVideoURL(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSString *imageID = ApolloMediaMetadataIDFromVideoURL(videoURL);
    if (imageID.length > 0) {
        NSDictionary *entry = mediaMetadata[imageID];
        if ([entry isKindOfClass:[NSDictionary class]]) return entry;
    }
    NSString *absStr = videoURL.absoluteString;
    NSString *path = videoURL.path;
    for (NSString *key in mediaMetadata) {
        NSDictionary *entry = mediaMetadata[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *s = entry[@"s"];
        if (![s isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *k in @[@"mp4", @"gif", @"u"]) {
            NSString *candidate = s[k];
            if (![candidate isKindOfClass:[NSString class]]) continue;
            NSString *decoded = [candidate stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            if ([decoded isEqualToString:absStr]) return entry;
            // Path-only match for sig/query mismatches across renderings.
            NSURL *cu = [NSURL URLWithString:decoded];
            if (path.length > 0 && [cu.path isEqualToString:path]) return entry;
        }
    }
    return nil;
}

// Pick the largest signed preview thumbnail from a mediaMetadata entry.
// Entries look like: { p: [{u, x, y}, ...sorted ascending], s: {u, gif, mp4}, ... }
// The last p[] entry is the highest-resolution still thumbnail (PNG/WEBP)
// with a valid signature. Returns nil for RedditVideo entries (no p[]).
static NSURL *ApolloPosterURLFromMediaMetadata(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSDictionary *entry = ApolloMediaMetadataEntryForVideoURL(mediaMetadata, videoURL);
    if (!entry) return nil;

    NSArray *previews = entry[@"p"];
    if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
        id last = previews.lastObject;
        NSString *u = [last isKindOfClass:[NSDictionary class]] ? last[@"u"] : nil;
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSURL *out = [NSURL URLWithString:decoded];
            if (out) return out;
        }
    }
    // For giphy/animated entries with no p[], use s.gif directly — it's
    // a small signed animated GIF that renders inline as the thumbnail.
    NSDictionary *s = entry[@"s"];
    if ([s isKindOfClass:[NSDictionary class]]) {
        NSString *gif = s[@"gif"];
        if ([gif isKindOfClass:[NSString class]] && gif.length > 0) {
            NSString *decoded = [gif stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSURL *out = [NSURL URLWithString:decoded];
            if (out) return out;
        }
    }
    return nil;
}

// Returns the DASH manifest URL for a RedditVideo mediaMetadata entry,
// or nil if the entry isn't a video (or has no dashUrl). Used by the
// poster-frame-extraction path below.
static NSURL *ApolloDashURLFromMediaMetadata(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSDictionary *entry = ApolloMediaMetadataEntryForVideoURL(mediaMetadata, videoURL);
    if (!entry) return nil;
    NSString *u = entry[@"dashUrl"];
    if (![u isKindOfClass:[NSString class]] || u.length == 0) return nil;
    NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:decoded];
}

// MARK: - DASH poster extraction (for Reddit hosted video permalinks)

// Cache: assetID → UIImage (success) | NSNull (failed, don't retry)
// Pending callbacks coalesce concurrent fetches for the same asset.
static NSMutableDictionary *sApolloDashPosterCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sApolloDashPosterPending;
static dispatch_queue_t sApolloDashPosterQueue;
static void ApolloDashPosterInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloDashPosterCache = [NSMutableDictionary dictionary];
        sApolloDashPosterPending = [NSMutableDictionary dictionary];
        sApolloDashPosterQueue = dispatch_queue_create("ca.jeffrey.apollo.dashposter", DISPATCH_QUEUE_SERIAL);
    });
}

// Find the lowest-bitrate video MP4 Representation in a DASH MPD. Reddit
// orders Representations ascending by bitrate, so the first BaseURL after
// the video AdaptationSet header is the smallest.
static NSURL *ApolloLowestDashMP4URL(NSData *mpdData, NSURL *mpdURL) {
    if (mpdData.length == 0 || !mpdURL) return nil;
    NSString *xml = [[NSString alloc] initWithData:mpdData encoding:NSUTF8StringEncoding];
    if (xml.length == 0) return nil;

    NSRange searchRange = NSMakeRange(0, xml.length);
    NSRange videoSet = [xml rangeOfString:@"contentType=\"video\""];
    if (videoSet.location != NSNotFound) {
        searchRange = NSMakeRange(videoSet.location, xml.length - videoSet.location);
    }

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<BaseURL>([^<]+\\.mp4)</BaseURL>"
                             options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:searchRange];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *relative = [xml substringWithRange:[m rangeAtIndex:1]];
    return [NSURL URLWithString:relative relativeToURL:mpdURL].absoluteURL;
}

// Avg luminance check on a tiny downsample. Reddit videos often open
// with logo intros on black; we reject these as poster candidates.
static BOOL ApolloImageIsMostlyBlack(UIImage *img) {
    if (!img) return YES;
    size_t w = 32, h = 32;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint8_t *buf = (uint8_t *)calloc(w * h * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img.CGImage);
    uint64_t sum = 0;
    for (size_t i = 0; i < w * h; i++) {
        sum += (buf[i*4] * 299 + buf[i*4+1] * 587 + buf[i*4+2] * 114) / 1000;
    }
    free(buf);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return ((double)sum / (double)(w * h)) < 12.0; // ~5% luma
}

// Download the DASH MPD, find the smallest video MP4, decode multiple
// candidate frames and pick the first non-black one. Reddit videos often
// fade in from a logo/black intro, so frame at t=0 is usually black.
// Calls back on main queue with the UIImage (or nil on failure).
// Coalesces concurrent calls for the same assetID.
static void ApolloFetchDashPoster(NSString *assetID, NSURL *dashURL,
                                   void (^completion)(UIImage *poster)) {
    if (!assetID.length || !dashURL || !completion) {
        if (completion) completion(nil);
        return;
    }
    ApolloDashPosterInit();
    void (^cb)(UIImage *) = [completion copy];

    dispatch_async(sApolloDashPosterQueue, ^{
        id cached = sApolloDashPosterCache[assetID];
        if (cached) {
            UIImage *out = (cached == [NSNull null]) ? nil : (UIImage *)cached;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
            return;
        }
        NSMutableArray *pending = sApolloDashPosterPending[assetID];
        if (pending) { [pending addObject:cb]; return; }
        sApolloDashPosterPending[assetID] = [NSMutableArray arrayWithObject:cb];

        void (^deliver)(UIImage *) = ^(UIImage *result) {
            dispatch_async(sApolloDashPosterQueue, ^{
                sApolloDashPosterCache[assetID] = result ?: (id)[NSNull null];
                NSArray *cbs = [sApolloDashPosterPending[assetID] copy];
                [sApolloDashPosterPending removeObjectForKey:assetID];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (void (^c)(UIImage *) in cbs) c(result);
                });
            });
        };

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:dashURL
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:8.0];
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (error || status < 200 || status >= 300 || data.length == 0) {
                ApolloLog(@"[InlineImages] DASH MPD fetch FAIL asset=%@ status=%ld err=%@",
                          assetID, (long)status, error.localizedDescription ?: @"nil");
                deliver(nil);
                return;
            }
            NSURL *mp4URL = ApolloLowestDashMP4URL(data, dashURL);
            if (!mp4URL) {
                ApolloLog(@"[InlineImages] DASH parse FAIL asset=%@", assetID);
                deliver(nil);
                return;
            }
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mp4URL options:nil];
            [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
                if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
                    ApolloLog(@"[InlineImages] DASH asset load FAIL asset=%@", assetID);
                    deliver(nil);
                    return;
                }
                AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
                gen.appliesPreferredTrackTransform = YES;
                gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.5, 600);
                gen.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.5, 600);

                Float64 durSec = CMTIME_IS_NUMERIC(asset.duration)
                    ? CMTimeGetSeconds(asset.duration) : 0;
                NSMutableArray<NSValue *> *times = [NSMutableArray array];
                for (NSNumber *t in @[@3.0, @5.0, @1.5, @0.5, @0.0]) {
                    Float64 v = t.doubleValue;
                    if (durSec <= 0 || v < durSec) {
                        [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(v, 600)]];
                    }
                }
                if (times.count == 0) [times addObject:[NSValue valueWithCMTime:kCMTimeZero]];

                __block BOOL delivered = NO;
                __block UIImage *darkFallback = nil;
                __block NSInteger remaining = (NSInteger)times.count;
                __block AVAssetImageGenerator *retainedGen = gen;

                [gen generateCGImagesAsynchronouslyForTimes:times
                    completionHandler:^(CMTime requested, CGImageRef cgImage,
                                        CMTime actualT, AVAssetImageGeneratorResult res,
                                        NSError *genError) {
                    @synchronized (retainedGen ?: (id)@"x") {
                        if (delivered) return;
                        remaining--;
                        if (res == AVAssetImageGeneratorSucceeded && cgImage) {
                            UIImage *ui = [UIImage imageWithCGImage:cgImage];
                            BOOL dark = ApolloImageIsMostlyBlack(ui);
                            if (!dark) {
                                delivered = YES;
                                retainedGen = nil;
                                deliver(ui);
                                return;
                            }
                            if (!darkFallback) darkFallback = ui;
                        }
                        if (remaining <= 0 && !delivered) {
                            delivered = YES;
                            retainedGen = nil;
                            deliver(darkFallback);
                        }
                    }
                }];
            }];
        }];
        [task resume];
    });
}

static NSURL *ApolloNormalizeInlineImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return url;

    // Imgur share URL → i.imgur.com/<id>.jpeg. The CDN serves the
    // underlying media (incl. animated GIFs) regardless of requested ext.
    if (ApolloIsImgurShareURL(url)) {
        NSString *imgurID = [url.path substringFromIndex:1];
        NSURL *canonical = [NSURL URLWithString:
            [NSString stringWithFormat:@"https://i.imgur.com/%@.jpeg", imgurID]];
        if (canonical) return canonical;
    }

    NSString *s = [url absoluteString];
    if (![s containsString:@"&amp;"]) return url;
    NSString *decoded = [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSURL *out = [NSURL URLWithString:decoded];
    return out ?: url;
}

// YES if the rendered text for a URL range looks like a bare URL (text
// contains the URL path, no whitespace) vs markdown link text. Bare-URL
// ranges are deleted from the trailing text since the inline image
// stands in for them; markdown-link ranges are preserved.
static BOOL ApolloRangeTextLooksLikeBareURL(NSAttributedString *attr, NSRange range, NSURL *url) {
    if (range.location + range.length > attr.string.length) return NO;
    NSString *text = [[attr.string substringWithRange:range]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *path = url.path;
    if (text.length == 0 || path.length == 0) return NO;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return NO;
    return [text rangeOfString:path].location != NSNotFound;
}

// A comment/post inline GIF is written in markdown as `[GIF](url)` (or
// `![gif](url)`), so once we render the GIF inline the decomposed text node
// would still show a redundant "GIF" label directly beneath it. Issue #392:
// when the link/alt text is exactly the default word "gif" we drop it (the GIF
// is self-evidently a GIF). Custom alt text like `[my dancing cat](url)` is NOT
// the default word, so it is kept and shown beneath the image as before.
static BOOL ApolloRangeTextIsDefaultGIFLabel(NSAttributedString *attr, NSRange range) {
    if (range.location + range.length > attr.string.length) return NO;
    NSString *text = [[attr.string substringWithRange:range]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [text caseInsensitiveCompare:@"gif"] == NSOrderedSame;
}

static CGFloat ApolloAspectRatioFromURL(NSURL *url) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *w = nil, *h = nil;
    for (NSURLQueryItem *q in c.queryItems) {
        NSString *name = [q.name lowercaseString];
        if ([name isEqualToString:@"width"] || [name isEqualToString:@"w"]) w = q.value;
        else if ([name isEqualToString:@"height"] || [name isEqualToString:@"h"]) h = q.value;
    }
    if (w.length == 0 || h.length == 0) return 0;
    double wv = [w doubleValue], hv = [h doubleValue];
    if (wv <= 0 || hv <= 0) return 0;
    // No clamping here — the layout-time wrapper applies the real bounds
    // (kApolloMin/MaxContainerRatio). Returning the raw ratio also lets
    // the wrapper detect "letterboxed" correctly for the border toggle.
    return (CGFloat)(hv / wv);
}

@interface ApolloImageChestAlbumViewController : UIViewController <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic) NSInteger initialIndex;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UILabel *loadingLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic) NSInteger imageLoadCompletedCount;
@property (nonatomic) NSInteger imageLoadTotalCount;
@property (nonatomic) BOOL controlsVisible;
@property (nonatomic) CGSize lastLayoutSize;
// Original downloaded bytes per page index — used for save/share so GIFs and
// WebPs keep their exact data instead of being re-encoded from a UIImage.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *imageDataByIndex;
// In-flight image downloads; their NSProgress drives the progress bar.
@property (nonatomic, strong) NSMutableArray<NSURLSessionDataTask *> *imageTasks;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;
// The album's post page URL (imgchest.com/p/...), when known — enables the
// "Share Album Link" action alongside per-image sharing.
@property (nonatomic, copy) NSURL *albumURL;
- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items initialIndex:(NSInteger)initialIndex;
@end

@implementation ApolloImageChestAlbumViewController

- (instancetype)initWithItems:(NSArray<NSDictionary *> *)items initialIndex:(NSInteger)initialIndex {
    self = [super init];
    if (self) {
        _items = [items copy] ?: @[];
        _initialIndex = MAX(0, MIN(initialIndex, (NSInteger)_items.count - 1));
        _controlsVisible = YES;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIInterfaceOrientation orientation = ((UIWindowScene *)scene).interfaceOrientation;
        if (orientation != UIInterfaceOrientationUnknown) return orientation;
    }
    return UIInterfaceOrientationPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.imageLoadTotalCount = (NSInteger)self.items.count;
    self.imageLoadCompletedCount = 0;
    self.imageDataByIndex = [NSMutableDictionary dictionary];
    self.imageTasks = [NSMutableArray array];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.pagingEnabled = YES;
    self.scrollView.delegate = self;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.backgroundColor = UIColor.blackColor;
    [self.view addSubview:self.scrollView];

    for (NSUInteger i = 0; i < self.items.count; i++) {
        UIView *page = [[UIView alloc] initWithFrame:CGRectZero];
        page.backgroundColor = UIColor.blackColor;
        page.tag = 2000 + (NSInteger)i;

        UIScrollView *zoomScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        zoomScrollView.tag = 4000 + (NSInteger)i;
        zoomScrollView.delegate = self;
        zoomScrollView.minimumZoomScale = 1.0;
        zoomScrollView.maximumZoomScale = 4.0;
        zoomScrollView.bouncesZoom = YES;
        zoomScrollView.showsHorizontalScrollIndicator = NO;
        zoomScrollView.showsVerticalScrollIndicator = NO;
        zoomScrollView.backgroundColor = UIColor.blackColor;
        zoomScrollView.panGestureRecognizer.enabled = NO;
        if (@available(iOS 11.0, *)) {
            zoomScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }

        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 3000 + (NSInteger)i;
        imageView.backgroundColor = UIColor.blackColor;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        [zoomScrollView addSubview:imageView];
        [page addSubview:zoomScrollView];
        [self.scrollView addSubview:page];

        NSURL *imageURL = [self.items[i][@"url"] isKindOfClass:[NSURL class]] ? self.items[i][@"url"] : nil;
        if (imageURL) {
            __weak UIImageView *weakImageView = imageView;
            __weak UIScrollView *weakZoomScrollView = zoomScrollView;
            __weak ApolloImageChestAlbumViewController *weakSelf = self;
            NSInteger pageIndex = (NSInteger)i;
            NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:imageURL
                                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                UIImage *image = (!error && data.length > 0) ? [UIImage imageWithData:data] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (image) {
                        weakImageView.image = image;
                        [weakSelf apollo_layoutZoomScrollView:weakZoomScrollView resetZoom:(weakZoomScrollView.zoomScale <= weakZoomScrollView.minimumZoomScale + 0.01)];
                        // Keep the original bytes so Save/Share exports the
                        // exact file (animated GIFs survive intact).
                        if (data) weakSelf.imageDataByIndex[@(pageIndex)] = data;
                    }
                    [weakSelf apollo_imageLoadFinished];
                });
            }];
            [self.imageTasks addObject:task];
            [task resume];
        } else {
            [self apollo_imageLoadFinished];
        }
    }

    self.counterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.counterLabel.textColor = UIColor.whiteColor;
    self.counterLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    self.counterLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.counterLabel.layer.cornerRadius = 14.0;
    self.counterLabel.clipsToBounds = YES;
    // A "1 / 1" pill is noise when viewing a single image.
    self.counterLabel.hidden = self.items.count <= 1;
    [self.view addSubview:self.counterLabel];

    self.loadingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.loadingLabel.textColor = UIColor.whiteColor;
    self.loadingLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    self.loadingLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.loadingLabel.layer.cornerRadius = 13.0;
    self.loadingLabel.clipsToBounds = YES;
    [self.view addSubview:self.loadingLabel];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"Done" forState:UIControlStateNormal];
    self.closeButton.tintColor = UIColor.whiteColor;
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.closeButton.layer.cornerRadius = 16.0;
    self.closeButton.clipsToBounds = YES;
    [self.closeButton addTarget:self action:@selector(apollo_close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.closeButton];

    // Share/Save menu (issue #332: the viewer had no save or share options).
    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    self.actionButton.tintColor = UIColor.whiteColor;
    self.actionButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.actionButton.layer.cornerRadius = 16.0;
    self.actionButton.clipsToBounds = YES;
    [self.actionButton addTarget:self action:@selector(apollo_actionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionButton];

    // True download progress for big albums, fed by the tasks' NSProgress.
    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.progressTintColor = UIColor.whiteColor;
    self.progressBar.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    [self.view addSubview:self.progressBar];
    if (self.imageTasks.count > 0) {
        self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                              target:self
                                                            selector:@selector(apollo_progressTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
    } else {
        self.progressBar.hidden = YES;
    }

    // Transient confirmation ("Saved", "Saved 12 images", ...).
    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toastLabel.textColor = UIColor.whiteColor;
    self.toastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    self.toastLabel.layer.cornerRadius = 14.0;
    self.toastLabel.clipsToBounds = YES;
    self.toastLabel.alpha = 0.0;
    [self.view addSubview:self.toastLabel];

    UITapGestureRecognizer *tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_viewerTapped:)];
    tapRecognizer.numberOfTapsRequired = 1;
    tapRecognizer.cancelsTouchesInView = NO;
    tapRecognizer.delegate = self;
    [self.view addGestureRecognizer:tapRecognizer];

    // Long-press an image for Save/Share (issue #332).
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_viewerLongPressed:)];
    longPress.delegate = self;
    [self.view addGestureRecognizer:longPress];

    // Swipe down to dismiss, like Apollo's native media viewer.
    self.dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_dismissPanned:)];
    self.dismissPan.delegate = self;
    [self.view addGestureRecognizer:self.dismissPan];

    [self updateCounterForPage:self.initialIndex];
    [self apollo_updateLoadingProgress];
    [self apollo_setControlsVisible:YES animated:NO reschedule:YES];
}

- (void)dealloc {
    [_progressTimer invalidate];
    [_autoHideTimer invalidate];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self apollo_cancelControlsAutoHide];

    // Tear down promptly when the viewer is actually going away. The repeating
    // progressTimer targets self, so until it's invalidated dealloc can't run;
    // if the user taps Done / swipes to dismiss while downloads are still in
    // flight, the viewer (and its imageTasks) would otherwise stay alive until
    // every task finished. The completion blocks capture weakSelf, so
    // cancelling the tasks is safe. Gate on isBeingDismissed/isMovingFromParent
    // so a transient disappearance (e.g. presenting the share sheet) doesn't
    // cancel still-loading downloads.
    if (self.isBeingDismissed || self.isMovingFromParentViewController) {
        [self.progressTimer invalidate];
        self.progressTimer = nil;
        for (NSURLSessionDataTask *task in self.imageTasks) {
            [task cancel];
        }
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // imageDataByIndex keeps the full original bytes of every page for the
    // viewer's lifetime so Save/Share preserves GIFs/WebPs exactly. For a large
    // multi-MB album that's a lot of resident memory; under pressure, drop
    // everything except the page on screen. Save/Share for a dropped page falls
    // back to re-encoding the displayed image (apollo_dataForPage:), losing only
    // animation — an acceptable trade when the system is asking for memory.
    if (self.imageDataByIndex.count == 0) return;
    // Guard scrollView access — a memory warning can arrive before the view is
    // loaded, in which case there's no on-screen page to preserve.
    NSNumber *current = (self.isViewLoaded && self.scrollView) ? @([self apollo_currentPageIndex]) : nil;
    NSData *keep = current ? self.imageDataByIndex[current] : nil;
    [self.imageDataByIndex removeAllObjects];
    if (keep) self.imageDataByIndex[current] = keep;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.scrollView.frame = bounds;
    self.scrollView.contentSize = CGSizeMake(bounds.size.width * self.items.count, bounds.size.height);
    BOOL resetZoom = CGSizeEqualToSize(self.lastLayoutSize, CGSizeZero) || !CGSizeEqualToSize(self.lastLayoutSize, bounds.size);

    for (NSUInteger i = 0; i < self.items.count; i++) {
        UIView *page = [self.scrollView viewWithTag:2000 + (NSInteger)i];
        page.frame = CGRectMake(bounds.size.width * i, 0, bounds.size.width, bounds.size.height);
        UIScrollView *zoomScrollView = [page viewWithTag:4000 + (NSInteger)i];
        zoomScrollView.frame = page.bounds;
        [self apollo_layoutZoomScrollView:zoomScrollView resetZoom:resetZoom];
    }

    CGFloat safeTop = 16.0;
    if (@available(iOS 11.0, *)) safeTop += self.view.safeAreaInsets.top;
    self.closeButton.frame = CGRectMake(bounds.size.width - 84.0, safeTop, 68.0, 32.0);
    self.actionButton.frame = CGRectMake(16.0, safeTop, 44.0, 32.0);
    self.counterLabel.frame = CGRectMake((bounds.size.width - 86.0) * 0.5, safeTop, 86.0, 28.0);
    self.loadingLabel.frame = CGRectMake((bounds.size.width - 132.0) * 0.5, CGRectGetMaxY(self.counterLabel.frame) + 8.0, 132.0, 26.0);
    self.progressBar.frame = CGRectMake(24.0, CGRectGetMaxY(self.loadingLabel.frame) + 8.0, bounds.size.width - 48.0, 3.0);
    CGFloat safeBottom = 24.0;
    if (@available(iOS 11.0, *)) safeBottom += self.view.safeAreaInsets.bottom;
    self.toastLabel.frame = CGRectMake((bounds.size.width - 200.0) * 0.5, bounds.size.height - safeBottom - 30.0, 200.0, 28.0);
    [self.scrollView setContentOffset:CGPointMake(bounds.size.width * self.initialIndex, 0.0) animated:NO];
    self.lastLayoutSize = bounds.size;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != self.scrollView) return;
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / MAX(scrollView.bounds.size.width, 1.0));
    [self updateCounterForPage:page];
    [self apollo_scheduleControlsAutoHide];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.scrollView) return;
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / MAX(scrollView.bounds.size.width, 1.0));
    [self updateCounterForPage:page];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    if (scrollView == self.scrollView) return nil;
    UIView *imageView = [scrollView viewWithTag:scrollView.tag - 1000];
    return [imageView isKindOfClass:[UIImageView class]] ? imageView : nil;
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    if (scrollView == self.scrollView) return;
    [self apollo_setControlsVisible:NO animated:YES reschedule:NO];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView == self.scrollView) return;
    scrollView.panGestureRecognizer.enabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01;
    UIImageView *imageView = (UIImageView *)[self viewForZoomingInScrollView:scrollView];
    [self apollo_centerImageView:imageView inScrollView:scrollView];
}

- (void)updateCounterForPage:(NSInteger)page {
    if (self.items.count == 0) {
        self.counterLabel.text = @"";
        return;
    }
    NSInteger clamped = MAX(0, MIN(page, (NSInteger)self.items.count - 1));
    self.initialIndex = clamped;
    self.counterLabel.text = [NSString stringWithFormat:@"%ld / %lu", (long)clamped + 1, (unsigned long)self.items.count];
}

- (void)apollo_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)apollo_imageLoadFinished {
    self.imageLoadCompletedCount = MIN(self.imageLoadCompletedCount + 1, self.imageLoadTotalCount);
    [self apollo_updateLoadingProgress];
}

- (void)apollo_updateLoadingProgress {
    NSInteger total = MAX(self.imageLoadTotalCount, 0);
    NSInteger done = MAX(0, MIN(self.imageLoadCompletedCount, total));
    if (total <= 0 || done >= total) {
        self.loadingLabel.text = total > 0 ? @"Loaded" : @"";
        [self.progressTimer invalidate];
        self.progressTimer = nil;
        [UIView animateWithDuration:0.2 animations:^{
            self.loadingLabel.alpha = 0.0;
            self.progressBar.alpha = 0.0;
        }];
        return;
    }

    // Percent only — the counter pill above already shows position/total.
    NSInteger percent = (NSInteger)llround([self apollo_overallDownloadFraction] * 100.0);
    self.loadingLabel.alpha = self.controlsVisible ? 1.0 : 0.0;
    self.loadingLabel.text = [NSString stringWithFormat:@"Loading %ld%%", (long)percent];
    (void)done;
}

// Byte-accurate overall progress: mean of each download task's own
// NSProgress. The old count-of-finished-images percentage sat at 0% while
// every image was mid-download and then jumped — this moves smoothly.
- (double)apollo_overallDownloadFraction {
    if (self.imageTasks.count == 0) return 1.0;
    double sum = 0.0;
    for (NSURLSessionDataTask *task in self.imageTasks) {
        double fraction = task.progress.fractionCompleted;
        if (task.state == NSURLSessionTaskStateCompleted) fraction = 1.0;
        sum += MAX(0.0, MIN(fraction, 1.0));
    }
    return sum / (double)self.imageTasks.count;
}

- (void)apollo_progressTimerFired:(NSTimer *)timer {
    [self.progressBar setProgress:(float)[self apollo_overallDownloadFraction] animated:YES];
    [self apollo_updateLoadingProgress];
}

- (BOOL)apollo_loadingInProgress {
    NSInteger total = MAX(self.imageLoadTotalCount, 0);
    NSInteger done = MAX(0, MIN(self.imageLoadCompletedCount, total));
    return total > 0 && done < total;
}

#pragma mark Save / Share (issue #332)

- (NSInteger)apollo_currentPageIndex {
    NSInteger page = (NSInteger)llround(self.scrollView.contentOffset.x / MAX(self.scrollView.bounds.size.width, 1.0));
    return MAX(0, MIN(page, (NSInteger)self.items.count - 1));
}

// Original bytes if the download kept them; falls back to re-encoding the
// displayed UIImage (e.g. if the data was never stored).
- (NSData *)apollo_dataForPage:(NSInteger)page {
    NSData *data = self.imageDataByIndex[@(page)];
    if (data.length > 0) return data;
    UIImageView *imageView = (UIImageView *)[self.scrollView viewWithTag:3000 + page];
    UIImage *image = [imageView isKindOfClass:[UIImageView class]] ? imageView.image : nil;
    return image ? UIImagePNGRepresentation(image) : nil;
}

// Temp file with the original filename/extension so shares and saves keep
// the real type (GIF stays GIF).
- (NSURL *)apollo_tempFileURLForPage:(NSInteger)page {
    NSData *data = [self apollo_dataForPage:page];
    if (data.length == 0) return nil;
    NSURL *sourceURL = [self.items[page][@"url"] isKindOfClass:[NSURL class]] ? self.items[page][@"url"] : nil;
    NSString *name = sourceURL.lastPathComponent.length > 0 ? sourceURL.lastPathComponent : [NSString stringWithFormat:@"image-%ld.png", (long)page + 1];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    return [data writeToURL:fileURL atomically:YES] ? fileURL : nil;
}

- (void)apollo_actionButtonTapped:(UIButton *)sender {
    [self apollo_presentActionsForPage:[self apollo_currentPageIndex] fromView:sender];
}

- (void)apollo_viewerLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self apollo_presentActionsForPage:[self apollo_currentPageIndex] fromView:self.view];
}

- (void)apollo_presentActionsForPage:(NSInteger)page fromView:(UIView *)sourceView {
    [self apollo_cancelControlsAutoHide];
    NSString *title = self.items.count > 1
        ? [NSString stringWithFormat:@"Image %ld of %lu", (long)page + 1, (unsigned long)self.items.count]
        : nil;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak ApolloImageChestAlbumViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save Image" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf apollo_saveImagesAtIndexes:@[@(page)]];
    }]];
    if (self.items.count > 1) {
        NSMutableArray<NSNumber *> *all = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.items.count; i++) [all addObject:@(i)];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Save All %lu Images", (unsigned long)self.items.count]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [weakSelf apollo_saveImagesAtIndexes:all];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:self.items.count > 1 ? @"Share Image" : @"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf apollo_shareImageAtIndex:page fromView:sourceView];
    }]];
    if (self.albumURL && self.items.count > 1) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Album Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_shareAlbumLinkFromView:sourceView];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = sourceView && sourceView != self.view ? sourceView.bounds
                                                                   : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)apollo_saveImagesAtIndexes:(NSArray<NSNumber *> *)indexes {
    __weak ApolloImageChestAlbumViewController *weakSelf = self;
    void (^performSave)(void) = ^{
        NSMutableArray<NSData *> *payloads = [NSMutableArray array];
        for (NSNumber *index in indexes) {
            NSData *data = [weakSelf apollo_dataForPage:index.integerValue];
            if (data.length > 0) [payloads addObject:data];
        }
        if (payloads.count == 0) {
            [weakSelf apollo_showToast:@"Nothing to save yet"];
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            for (NSData *data in payloads) {
                PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
            }
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [weakSelf apollo_showToast:payloads.count == 1 ? @"Saved"
                                              : [NSString stringWithFormat:@"Saved %lu images", (unsigned long)payloads.count]];
                } else {
                    ApolloLog(@"[InlineImages] album save failed: %@", error.localizedDescription);
                    [weakSelf apollo_showToast:@"Save failed"];
                }
            });
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) performSave();
                else [weakSelf apollo_showToast:@"Photos access denied"];
            });
        }];
    } else if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        performSave();
    } else {
        [self apollo_showToast:@"Photos access denied"];
    }
}

- (void)apollo_shareImageAtIndex:(NSInteger)page fromView:(UIView *)sourceView {
    NSURL *fileURL = [self apollo_tempFileURLForPage:page];
    NSURL *sourceURL = [self.items[page][@"url"] isKindOfClass:[NSURL class]] ? self.items[page][@"url"] : nil;
    NSArray *activityItems = fileURL ? @[fileURL] : (sourceURL ? @[sourceURL] : nil);
    if (!activityItems) {
        [self apollo_showToast:@"Nothing to share yet"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:activityItems applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = sourceView && sourceView != self.view ? sourceView.bounds
                                                                   : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)apollo_shareAlbumLinkFromView:(UIView *)sourceView {
    if (!self.albumURL) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[self.albumURL] applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = sourceView && sourceView != self.view ? sourceView.bounds
                                                                   : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)apollo_showToast:(NSString *)text {
    self.toastLabel.text = text;
    [self.view bringSubviewToFront:self.toastLabel];
    [UIView animateWithDuration:0.2 animations:^{
        self.toastLabel.alpha = 1.0;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            self.toastLabel.alpha = 0.0;
        }];
    });
}

#pragma mark Swipe-down dismiss

- (void)apollo_dismissPanned:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.view.superview ?: self.view];
    CGFloat dy = MAX(0.0, translation.y);
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self apollo_setControlsVisible:NO animated:YES reschedule:NO];
            break;
        case UIGestureRecognizerStateChanged:
            self.view.transform = CGAffineTransformMakeTranslation(0.0, dy);
            self.view.alpha = 1.0 - MIN(dy / 600.0, 0.4);
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [recognizer velocityInView:self.view].y;
            if (recognizer.state == UIGestureRecognizerStateEnded && (dy > 140.0 || velocity > 900.0)) {
                [self dismissViewControllerAnimated:YES completion:nil];
            } else {
                [UIView animateWithDuration:0.25
                                      delay:0.0
                     usingSpringWithDamping:0.8
                      initialSpringVelocity:0.0
                                    options:0
                                 animations:^{
                    self.view.transform = CGAffineTransformIdentity;
                    self.view.alpha = 1.0;
                } completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

- (void)apollo_viewerTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    [self apollo_setControlsVisible:!self.controlsVisible animated:YES reschedule:YES];
}

- (void)apollo_setControlsVisible:(BOOL)visible animated:(BOOL)animated reschedule:(BOOL)reschedule {
    self.controlsVisible = visible;
    self.closeButton.userInteractionEnabled = visible;
    self.actionButton.userInteractionEnabled = visible;
    CGFloat controlsAlpha = visible ? 1.0 : 0.0;
    CGFloat loadingAlpha = (visible && [self apollo_loadingInProgress]) ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        self.closeButton.alpha = controlsAlpha;
        self.actionButton.alpha = controlsAlpha;
        self.counterLabel.alpha = controlsAlpha;
        self.loadingLabel.alpha = loadingAlpha;
        self.progressBar.alpha = loadingAlpha;
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
    if (visible && reschedule) {
        [self apollo_scheduleControlsAutoHide];
    } else if (!visible) {
        [self apollo_cancelControlsAutoHide];
    }
}

- (void)apollo_scheduleControlsAutoHide {
    [self apollo_cancelControlsAutoHide];
    if (!self.controlsVisible) return;
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                          target:self
                                                        selector:@selector(apollo_autoHideControlsTimerFired:)
                                                        userInfo:nil
                                                         repeats:NO];
}

- (void)apollo_cancelControlsAutoHide {
    [self.autoHideTimer invalidate];
    self.autoHideTimer = nil;
}

- (void)apollo_autoHideControlsTimerFired:(NSTimer *)timer {
    [self apollo_setControlsVisible:NO animated:YES reschedule:NO];
}

- (CGRect)apollo_aspectFitFrameForImage:(UIImage *)image inBounds:(CGRect)bounds {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0 || bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        return bounds;
    }
    CGFloat scale = MIN(bounds.size.width / image.size.width, bounds.size.height / image.size.height);
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    return CGRectMake((bounds.size.width - size.width) * 0.5,
                      (bounds.size.height - size.height) * 0.5,
                      size.width,
                      size.height);
}

- (void)apollo_layoutZoomScrollView:(UIScrollView *)zoomScrollView resetZoom:(BOOL)resetZoom {
    if (![zoomScrollView isKindOfClass:[UIScrollView class]]) return;
    UIImageView *imageView = (UIImageView *)[self viewForZoomingInScrollView:zoomScrollView];
    if (![imageView isKindOfClass:[UIImageView class]]) return;

    if (resetZoom || zoomScrollView.zoomScale <= zoomScrollView.minimumZoomScale + 0.01) {
        zoomScrollView.zoomScale = zoomScrollView.minimumZoomScale;
        imageView.frame = [self apollo_aspectFitFrameForImage:imageView.image inBounds:zoomScrollView.bounds];
        zoomScrollView.contentSize = imageView.frame.size;
    }
    zoomScrollView.panGestureRecognizer.enabled = zoomScrollView.zoomScale > zoomScrollView.minimumZoomScale + 0.01;
    [self apollo_centerImageView:imageView inScrollView:zoomScrollView];
}

- (void)apollo_centerImageView:(UIImageView *)imageView inScrollView:(UIScrollView *)zoomScrollView {
    if (![imageView isKindOfClass:[UIImageView class]] || ![zoomScrollView isKindOfClass:[UIScrollView class]]) return;
    CGSize boundsSize = zoomScrollView.bounds.size;
    CGRect frame = imageView.frame;
    frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) * 0.5 : 0.0;
    frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) * 0.5 : 0.0;
    imageView.frame = frame;
    zoomScrollView.contentSize = frame.size;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *view = touch.view;
    while (view) {
        if (view == self.closeButton || view == self.actionButton) return NO;
        view = view.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.dismissPan) return YES;
    // Swipe-down dismiss only engages on a clearly downward drag while the
    // current image isn't zoomed — horizontal drags page, zoomed drags pan.
    UIScrollView *zoom = (UIScrollView *)[self.scrollView viewWithTag:4000 + [self apollo_currentPageIndex]];
    if ([zoom isKindOfClass:[UIScrollView class]] && zoom.zoomScale > zoom.minimumZoomScale + 0.01) return NO;
    CGPoint velocity = [self.dismissPan velocityInView:self.view];
    return velocity.y > 0.0 && fabs(velocity.y) > fabs(velocity.x) * 1.5;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

// MARK: - Tap dispatcher + UIContextMenuInteraction delegate (singleton)

@interface ApolloInlineImageDispatcher : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)shared;
- (void)imageNodeTapped:(id)sender;
- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image;
- (void)updateAspectRatioForImageNode:(id)imageNode imageSize:(CGSize)size;
@end

static UIViewController *ApolloTopVCFromView(UIView *v);
static void ApolloOpenImageChestURLNormally(NSURL *url);
static BOOL ApolloPresentOrResolveImageChestAlbumURL(NSURL *url, UIView *sourceView, void (^fallback)(void));

@implementation ApolloInlineImageDispatcher

+ (instancetype)shared {
    static ApolloInlineImageDispatcher *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ApolloInlineImageDispatcher alloc] init]; });
    return s;
}

// Walk supernodes from `imageNode` searching for an object responding to
// `sel`. Returns the first match or nil.
static id ApolloFindResponderForSelector(SEL sel, id imageNode) {
    id cursor = imageNode;
    for (int hops = 0; cursor && hops < 24; hops++) {
        if ([cursor respondsToSelector:sel]) return cursor;
        if (![cursor respondsToSelector:@selector(supernode)]) break;
        cursor = [cursor performSelector:@selector(supernode)];
    }
    return nil;
}

- (void)imageNodeTapped:(id)imageNode {
    // Tap-to-play GIFs: the play button / corner pause badge overlay
    // (ApolloPlayOverlayContainer) swallows taps on its own icon zone and
    // toggles inline playback there. Any other tap on the GIF lands here
    // and falls through to the media viewer below — fullscreen stays
    // reachable with the overlay up, exactly like a plain image.
    //
    // Self-heal: Texture can recycle the node's backing view on a
    // relayout-from-above (async cover sizing, metadata rebuilds) and
    // silently drop the container (see ApolloSchedulePlayOverlayReassert).
    // With the overlay detached there is no icon zone, so without this a
    // tap-to-play GIF would be unplayable inline until a settings change.
    // Fall back to the whole-GIF toggle in that state; Start/Stop re-run
    // the overlay mapper, which re-attaches the proper overlay.
    if ([objc_getAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey) boolValue] &&
        !ApolloShouldAutoplayInlineGIFCached() && ApolloPausedInlineGIFWantsPlayOverlay()) {
        UIView *overlay = objc_getAssociatedObject(imageNode, &kApolloPlayOverlayViewKey);
        UIView *nodeView = ([imageNode respondsToSelector:@selector(isNodeLoaded)] && [imageNode isNodeLoaded])
            ? [imageNode view] : nil;
        if (!overlay || !nodeView || overlay.superview != nodeView) {
            ApolloLog(@"[AutoplayGIF] tap heal node=%p overlay=%p detached=1", imageNode, overlay);
            if ([objc_getAssociatedObject(imageNode, &kApolloInlineGIFUserForcedPlayKey) boolValue]) {
                ApolloStopInlineGIFPlayback((ASNetworkImageNode *)imageNode);
            } else {
                ApolloStartInlineGIFPlayback((ASNetworkImageNode *)imageNode);
            }
            return;
        }
    }

    NSArray *imageChestItems = objc_getAssociatedObject(imageNode, &kApolloImageChestItemsKey);
    if (imageChestItems.count > 0) {
        UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
        NSURL *albumURL = objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey);
        if (![albumURL isKindOfClass:[NSURL class]] || !ApolloImageChestIsPostURL(albumURL)) albumURL = nil;
        if (ApolloPresentImageChestItemsWithAlbumURL(imageChestItems, view, 0, albumURL)) return;
    }

    // Prefer the original album/gallery/share URL when present so taps
    // route to Apollo's full multi-image album viewer (for albums) or
    // the user-posted URL (for normalized share links); otherwise use
    // the single-image loaded URL.
    NSURL *url = objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey)
              ?: objc_getAssociatedObject(imageNode, &kApolloImageURLKey);
    if (![url isKindOfClass:[NSURL class]]) return;
    if (ApolloImageChestIsPostURL(url)) {
        UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
        ApolloPresentOrResolveImageChestAlbumURL(url, view, ^{
            ApolloOpenImageChestURLNormally(url);
        });
        return;
    }
    // Single ImgChest images open in the same viewer as albums, so the
    // chrome (Share top-left, Done top-right) and save options are
    // consistent instead of falling through to the native X-button viewer.
    if (ApolloImageChestIsDirectImageURL(url)) {
        UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
        if (ApolloPresentImageChestItems(@[@{ @"url": url }], view, 0)) return;
    }

    ASDisplayNode *host = objc_getAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey);
    SEL sel = @selector(textNode:tappedLinkAttribute:value:atPoint:textRange:);
    id target = ApolloFindResponderForSelector(sel, imageNode) ?: ([host respondsToSelector:sel] ? host : nil);
    if (!target) {
        ApolloLog(@"[InlineImages] tap: no responder for %@", url);
        return;
    }

    // Apollo's MarkdownNode tap handler (sub_10042ddf8) only routes URLs to
    // MediaViewer when attr is the swift_once-initialized "ApolloLink"
    // string; NSLinkAttributeName etc. are silently ignored.
    id textArg = host ?: target;
    void (*msgSend)(id, SEL, id, id, id, CGPoint, NSRange) =
        (void (*)(id, SEL, id, id, id, CGPoint, NSRange))objc_msgSend;
    msgSend(target, sel, textArg, @"ApolloLink", url,
            CGPointZero, NSMakeRange(NSNotFound, 0));
}

#pragma mark - UIContextMenuInteractionDelegate

// Find the topmost presented view controller from a view in the hierarchy.
static UIViewController *ApolloTopVCFromView(UIView *v) {
    UIWindow *window = v.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Non-static: exported via ApolloCommon.h so other modules can open the
// viewer. Despite the name it is a generic zoomable image-album viewer;
// items are dictionaries with an @"url" NSURL. albumURL is the album's page
// URL when known — it enables the viewer's "Share Album Link" action; pass
// nil otherwise.
BOOL ApolloPresentImageChestItemsWithAlbumURL(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex, NSURL *albumURL) {
    if (items.count == 0) return NO;
    UIViewController *top = ApolloTopVCFromView(sourceView);
    if (!top) return NO;

    ApolloImageChestAlbumViewController *viewer = [[ApolloImageChestAlbumViewController alloc] initWithItems:items initialIndex:initialIndex];
    viewer.albumURL = albumURL;
    [top presentViewController:viewer animated:YES completion:nil];
    return YES;
}

// Non-static: also used by ApolloFeedTextPostThumbnails to open a text post's
// embedded images fullscreen (declared in ApolloCommon.h). Thin wrapper over
// ApolloPresentImageChestItemsWithAlbumURL with no album link.
BOOL ApolloPresentImageChestItems(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex) {
    return ApolloPresentImageChestItemsWithAlbumURL(items, sourceView, initialIndex, nil);
}

static void ApolloOpenImageChestURLNormally(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
}

static BOOL ApolloPresentOrResolveImageChestAlbumURL(NSURL *url, UIView *sourceView, void (^fallback)(void)) {
    if (!ApolloImageChestIsPostURL(url)) return NO;

    NSDictionary *cached = ApolloImageChestCachedResolution(url);
    NSArray *cachedItems = [cached[@"images"] isKindOfClass:[NSArray class]] ? cached[@"images"] : nil;
    if (cachedItems.count > 0) {
        ApolloPresentImageChestItemsWithAlbumURL(cachedItems, sourceView, 0, url);
        return YES;
    }

    ApolloImageChestResolveURL(url, ^(NSDictionary *result) {
        NSArray *items = [result[@"images"] isKindOfClass:[NSArray class]] ? result[@"images"] : nil;
        if (items.count > 0) {
            ApolloPresentImageChestItemsWithAlbumURL(items, sourceView, 0, url);
        } else if (fallback) {
            fallback();
        }
    });
    return YES;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
    UIView *v = interaction.view;
    if (!v) return nil;
    NSURL *url = objc_getAssociatedObject(v, &kApolloOriginalImageURLKey)
              ?: objc_getAssociatedObject(v, &kApolloImageURLKey);
    if (![url isKindOfClass:[NSURL class]]) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        __weak UIView *weakView = v;
        UIAction *copy = [UIAction actionWithTitle:@"Copy Link"
                                              image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            UIPasteboard.generalPasteboard.URL = url;
        }];
        UIAction *share = [UIAction actionWithTitle:@"Share…"
                                               image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                           identifier:nil
                                             handler:^(__kindof UIAction *a) {
            UIView *vv = weakView;
            UIActivityViewController *avc = [[UIActivityViewController alloc]
                initWithActivityItems:@[url] applicationActivities:nil];
            UIViewController *top = ApolloTopVCFromView(vv);
            if (top) {
                avc.popoverPresentationController.sourceView = vv;
                avc.popoverPresentationController.sourceRect = vv.bounds;
                [top presentViewController:avc animated:YES completion:nil];
            }
        }];
        UIAction *open = [UIAction actionWithTitle:@"Open in Safari"
                                              image:[UIImage systemImageNamed:@"safari"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }];
        return [UIMenu menuWithTitle:@"" children:@[copy, share, open]];
    }];
}

- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image {
    ApolloLog(@"[InlineImages] DIDLOAD imageNode=%p hasImage=%d size=%@ url=%@",
              imageNode, image != nil, image ? NSStringFromCGSize(image.size) : @"nil",
              [imageNode respondsToSelector:@selector(URL)] ? [(ASNetworkImageNode *)imageNode URL] : nil);
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;
    [self updateAspectRatioForImageNode:imageNode imageSize:image.size];
}

// Update cached aspect ratio + trigger layout-from-above if it changed.
// Called from didLoadImage: (static images) and from our _locked_setAnimatedImage:
// hook below (GIFs / animated images, where didLoadImage: doesn't fire).
- (void)updateAspectRatioForImageNode:(id)imageNode imageSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    CGFloat newRatio = size.height / size.width;
    NSNumber *cur = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (cur && fabs(newRatio - [cur doubleValue]) < 0.01) return;
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(newRatio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineImages] ratio set imageNode=%p ratio=%.3f size=%@",
              imageNode, newRatio, NSStringFromCGSize(size));

    // Texture's internal "intrinsic size changed" hook; walks up to the
    // root signaling the table/collection to re-measure the row.
    SEL sel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    if (![imageNode respondsToSelector:sel]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL))objc_msgSend)(imageNode, sel);
    });
}

@end

// MARK: - Native inline animated media gating
//
// Apollo renders some comment/selftext animated media itself (giphy-picker
// tokens, native ![gif](...) embeds, animated snoomoji) as MarkdownNode
// children the tweak doesn't create. Those nodes were never marked as inline
// GIFs, so the FLAnimatedImageView hooks let them animate regardless of the
// Autoplay Inline GIFs mode. Flag any un-hosted animated node living under a
// MarkdownNode and gate it in place (stop/start only — no cover/overlay/URL
// reload machinery). Feed media (RichMediaNode) has no MarkdownNode ancestor
// and stays governed by Apollo's native autoplay setting.
static BOOL ApolloNodeDescendsFromMarkdownNode(ASDisplayNode *node) {
    ASDisplayNode *cursor = node.supernode;
    int depth = 0;
    while (cursor && depth < 12) {
        if ([NSStringFromClass([cursor class]) containsString:@"MarkdownNode"]) return YES;
        cursor = cursor.supernode;
        depth++;
    }
    return NO;
}

static void ApolloActivateNativeInlineGIFGate(ASDisplayNode *node) {
    ApolloFlagNativeInlineGIFNode(node);
    ApolloRegisterInlineGIFNode(node);
    if (!ApolloApplyNativeInlineGIFAutoplayGate(node) &&
        [node respondsToSelector:@selector(onDidLoad:)]) {
        // Node not loaded yet — gate the instant its view is created so the
        // animation never gets a free first run.
        __weak ASDisplayNode *weakNode = node;
        [node onDidLoad:^(__kindof ASDisplayNode *loaded) {
            ASDisplayNode *strong = weakNode;
            if (!strong || (id)loaded != (id)strong) return;
            ApolloApplyNativeInlineGIFAutoplayGate(strong);
        }];
    }
    ApolloLog(@"[AutoplayGIF] native inline GIF gated node=%p class=%@",
              node, NSStringFromClass([node class]));
}

// Mark a hosted inline GIF node's backing view the moment it exists — via
// onDidLoad for prefetched nodes — so the FLAnimatedImageView hooks gate
// playback from the very first frame. Marking used to wait for the playback
// policy to run with a downloaded cover, so a freshly loaded GIF animated for
// as long as its cover fetch took (seconds on slow hosts; indefinitely when
// the fetch failed) even with autoplay off.
static void ApolloMarkHostedInlineGIFViewWhenLoaded(ASNetworkImageNode *node, NSUInteger generation) {
    if (!node) return;
    if ([node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded]) {
        UIView *view = [node view];
        if (view) {
            ApolloMarkViewAsInlineGIF(view);
            UIView *animView = ApolloFindFLAnimatedImageViewInView(view);
            if (animView) ApolloApplyFLAnimatedImageViewAutoplayGate(animView);
        }
        return;
    }
    if (![node respondsToSelector:@selector(onDidLoad:)]) return;
    __weak ASNetworkImageNode *weakNode = node;
    [node onDidLoad:^(__kindof ASDisplayNode *loaded) {
        ASNetworkImageNode *strong = weakNode;
        if (!strong || (id)loaded != (id)strong) return;
        if (!ApolloInlineGIFGenerationMatches(strong, generation)) return;
        if (![objc_getAssociatedObject(strong, &kApolloInlineAnimatedGIFKey) boolValue]) return;
        UIView *view = [strong view];
        if (!view) return;
        ApolloMarkViewAsInlineGIF(view);
        UIView *animView = ApolloFindFLAnimatedImageViewInView(view);
        if (animView) ApolloApplyFLAnimatedImageViewAutoplayGate(animView);
        // Re-run the playback policy now that the view exists so the static
        // cover and (mode-dependent) play overlay land immediately.
        UIImage *storedCover = objc_getAssociatedObject(strong, &kApolloInlineGIFCoverImageKey);
        ApolloApplyInlineGIFPlaybackPolicyWithCover(strong, storedCover, 0);
    }];
}

static void ApolloGateNativeInlineAnimatedImageIfNeeded(ASDisplayNode *node) {
    if (!node) return;
    __weak ASDisplayNode *weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASDisplayNode *strong = weakNode;
        if (!strong || ApolloImageNodeHasInlineHost(strong)) return;
        if (ApolloNodeDescendsFromMarkdownNode(strong)) {
            ApolloActivateNativeInlineGIFGate(strong);
            return;
        }
        // The node may not be attached to its supernode yet (async decode) —
        // check once more after attachment settles.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ASDisplayNode *retryNode = weakNode;
            if (!retryNode || ApolloImageNodeHasInlineHost(retryNode)) return;
            if (!ApolloNodeDescendsFromMarkdownNode(retryNode)) return;
            ApolloActivateNativeInlineGIFGate(retryNode);
        });
    });
}

// MARK: - %hook ASImageNode (animated image — GIF support)
//
// ASNetworkImageNode bypasses the public setAnimatedImage: setter and calls
// _locked_setAnimatedImage: directly (Texture/Source/ASNetworkImageNode.mm
// lines 769, 822). Hooking the public setter never fires for GIFs. We hook
// the private locked setter, then defer our state mutation to the main
// queue so we don't touch ratio/layout while Texture holds the node lock.

%hook ASImageNode

- (void)_locked_setAnimatedImage:(id)animatedImage {
    BOOL hosted = ApolloImageNodeHasInlineHost(self);
    if (!hosted && animatedImage) {
        ApolloGateNativeInlineAnimatedImageIfNeeded((ASDisplayNode *)self);
    }
    if (hosted && animatedImage && !ApolloInlineGIFAnimatedImageArgumentIsUsable(animatedImage)) {
        ApolloLog(@"[InlineImages] _locked_setAnimatedImage rejecting unusable animatedImage node=%p", self);
        ApolloClearInlineGIFNodeState((ASNetworkImageNode *)self);
        return;
    }
    %orig;
    if (!hosted) return;

    if (!animatedImage) {
        if ([objc_getAssociatedObject(self, &kApolloInlineGIFReloadInFlightKey) boolValue]) {
            // Settings-refresh reload resets URL/image before re-setting them —
            // keep the node's inline-GIF state so the re-download re-gates.
            return;
        }
        __weak ASImageNode *weakSelf = self;
        NSUInteger generation = ApolloInlineGIFGenerationForNode(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            ASImageNode *strong = weakSelf;
            if (!strong || !ApolloInlineGIFGenerationMatches(strong, generation)) return;
            ApolloClearInlineGIFNodeState((ASNetworkImageNode *)strong);
        });
        return;
    }

    id retainedAnim = animatedImage;
    __weak ASImageNode *weakSelf = self;
    NSUInteger generation = ApolloInlineGIFGenerationForNode(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        ASImageNode *strong = weakSelf;
        if (!strong || !retainedAnim || !ApolloInlineGIFGenerationMatches(strong, generation)) return;

        id anim = retainedAnim;
        UIImage *cover = nil;
        BOOL ready = YES;
        if ([anim respondsToSelector:@selector(coverImageReady)]) {
            ready = [[anim valueForKey:@"coverImageReady"] boolValue];
        }
        if (ready && [anim respondsToSelector:@selector(coverImage)]) {
            cover = [anim valueForKey:@"coverImage"];
        }
        ApolloLog(@"[InlineImages] _locked_setAnimatedImage imageNode=%p ready=%d coverSize=%@",
                  strong, ready, cover ? NSStringFromCGSize(cover.size) : @"nil");

        if (cover && cover.size.width > 0 && cover.size.height > 0) {
            [[ApolloInlineImageDispatcher shared] updateAspectRatioForImageNode:strong imageSize:cover.size];
            objc_setAssociatedObject(strong, &kApolloInlineGIFCoverImageKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(strong, &kApolloInlineAnimatedGIFKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(strong, &kApolloInlineGIFAnimatedImageKey, anim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloRegisterInlineGIFNode(strong);

        ApolloMarkHostedInlineGIFViewWhenLoaded((ASNetworkImageNode *)strong, generation);
        // Attach the play button (or pause badge, when this set is the
        // tap-to-play re-inject) as soon as the view exists; no-ops until
        // node load, after which the playback policy's pause path installs.
        ApolloUpdateInlineGIFOverlayForNode((ASDisplayNode *)strong);

        ApolloApplyInlineGIFPlaybackPolicyWithCover((ASNetworkImageNode *)strong, cover, 0);
        if (cover && cover.size.width > 0 && cover.size.height > 0) return;
        // Cover not ready yet — install the protocol's ready callback.
        if ([anim respondsToSelector:@selector(setCoverImageReadyCallback:)]) {
            id capturedAnim = retainedAnim;
            void (^cb)(UIImage *) = ^(UIImage *coverImage) {
                ApolloLog(@"[InlineImages] coverImageReadyCallback imageNode=%p coverSize=%@",
                          weakSelf, coverImage ? NSStringFromCGSize(coverImage.size) : @"nil");
                ASImageNode *s = weakSelf;
                if (!s || !coverImage || coverImage.size.width <= 0 || !ApolloInlineGIFGenerationMatches(s, generation)) return;
                id storedAnim = objc_getAssociatedObject(s, &kApolloInlineGIFAnimatedImageKey);
                if (storedAnim && storedAnim != capturedAnim) return;
                objc_setAssociatedObject(s, &kApolloInlineAnimatedGIFKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(s, &kApolloInlineGIFAnimatedImageKey, capturedAnim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(s, &kApolloInlineGIFCoverImageKey, coverImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloRegisterInlineGIFNode(s);
                dispatch_async(dispatch_get_main_queue(), ^{
                    ASImageNode *readyNode = weakSelf;
                    if (!readyNode || !ApolloInlineGIFGenerationMatches(readyNode, generation)) return;
                    if (![objc_getAssociatedObject(readyNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;
                    id currentAnim = objc_getAssociatedObject(readyNode, &kApolloInlineGIFAnimatedImageKey);
                    if (currentAnim && currentAnim != capturedAnim) return;
                    [[ApolloInlineImageDispatcher shared] updateAspectRatioForImageNode:readyNode imageSize:coverImage.size];
                    ApolloApplyInlineGIFPlaybackPolicyWithCover((ASNetworkImageNode *)readyNode, coverImage, 0);
                });
            };
            [anim performSelector:@selector(setCoverImageReadyCallback:) withObject:cb];
        }
    });
}

- (void)dealloc {
    if (ApolloImageNodeHasInlineHost(self)) {
        ApolloCancelInlineGIFPendingPolicyBlocks(self);
        ApolloInlineGIFBumpGeneration(self);
        id anim = objc_getAssociatedObject(self, &kApolloInlineGIFAnimatedImageKey);
        ApolloClearInlineGIFCoverImageReadyCallback(anim);
    }
    %orig;
}

%end

%hook ASNetworkImageNode

- (void)setURL:(NSURL *)URL {
    if (ApolloImageNodeHasInlineHost(self) &&
        ![objc_getAssociatedObject(self, &kApolloInlineGIFReloadInFlightKey) boolValue]) {
        NSURL *previous = [self respondsToSelector:@selector(URL)] ? [self URL] : nil;
        if ((previous && URL && ![previous isEqual:URL]) || (previous && !URL)) {
            ApolloLog(@"[AutoplayGIF] clearing GIF state on URL change node=%p", self);
            ApolloClearInlineGIFNodeState(self);
        }
    }
    %orig;
}

- (void)clearImage {
    if (ApolloImageNodeHasInlineHost(self)) {
        ApolloClearInlineGIFNodeState(self);
    }
    %orig;
}

%end

static BOOL ApolloTopControllerIsImageChestViewer(UIWindow *window) {
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return [vc isKindOfClass:[ApolloImageChestAlbumViewController class]];
}

// Apollo's app delegate clamps most screens to portrait when Smart Rotation
// Lock is enabled, with a native exception for the Media Viewer. Give the
// Image Chest album viewer the same media-viewer orientation allowance.
%hook _TtC6Apollo11AppDelegate

- (NSUInteger)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (ApolloTopControllerIsImageChestViewer(window)) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return %orig;
}

%end

// MARK: - Image-node construction

// Forward decl: defined further down (after layout helpers). Used by
// ApolloBuildLeavesForTextNode below to look up or create the imageNode for
// a given URL via the per-MarkdownNode reuse cache.
static ASNetworkImageNode *ApolloImageNodeForURL(NSURL *normalizedURL,
                                                   ASDisplayNode *hostMarkdownNode);
static ASNetworkImageNode *ApolloVideoThumbnailNodeForURL(NSURL *normalizedURL,
                                                           ASDisplayNode *hostMarkdownNode);
static void ApolloInstallStackedCardForImageNode(ASNetworkImageNode *imageNode);

// Mirror the imageNode's tap/long-press URL associations onto its
// backing view once it's loaded — UIContextMenuInteraction reads from
// the view, not the node.
static void ApolloMirrorImageURLsToLoadedView(ASNetworkImageNode *imageNode) {
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)] || ![imageNode isNodeLoaded]) return;
    UIView *view = [imageNode view];
    if (!view) return;
    NSURL *tapURL = objc_getAssociatedObject(imageNode, &kApolloImageURLKey) ?: imageNode.URL;
    NSURL *originalURL = objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey);
    if (tapURL) objc_setAssociatedObject(view, &kApolloImageURLKey, tapURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (originalURL) objc_setAssociatedObject(view, &kApolloOriginalImageURLKey, originalURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Record the URL the user actually posted (different from the loaded
// CDN URL after normalization, or different from the resolved image
// URL after Imgur album lookup). Used for tap routing + Copy Link.
static void ApolloSetOriginalImageURL(ASNetworkImageNode *imageNode, NSURL *originalURL) {
    if (![originalURL isKindOfClass:[NSURL class]]) return;
    objc_setAssociatedObject(imageNode, &kApolloOriginalImageURLKey, originalURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloMirrorImageURLsToLoadedView(imageNode);
}

// Apply an async album resolution result to an imageNode. Sets the load
// URL, captures aspect ratio if available, and triggers cell relayout.
// Preserves kApolloOriginalImageURLKey so copy/share still use the user
// posted album URL instead of only the resolved cover image.
static void ApolloApplyResolvedAlbumImage(ASNetworkImageNode *imageNode, NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) return;
    NSURL *imageURL = [result[@"url"] isKindOfClass:[NSURL class]] ? result[@"url"] : nil;
    if (![imageURL isKindOfClass:[NSURL class]]) return;

    imageNode.URL = imageURL;
    NSArray *images = [result[@"images"] isKindOfClass:[NSArray class]] ? result[@"images"] : nil;
    if (images.count > 0) {
        objc_setAssociatedObject(imageNode, &kApolloImageChestItemsKey, images, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Set kApolloImageURLKey only if there's no album/gallery original
    // URL — otherwise tap should route to the album URL.
    if (!objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey)) {
        objc_setAssociatedObject(imageNode, &kApolloImageURLKey, imageURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloMirrorImageURLsToLoadedView(imageNode);

    NSNumber *width = [result[@"width"] respondsToSelector:@selector(doubleValue)] ? result[@"width"] : nil;
    NSNumber *height = [result[@"height"] respondsToSelector:@selector(doubleValue)] ? result[@"height"] : nil;
    if (width.doubleValue > 0 && height.doubleValue > 0) {
        CGFloat ratio = height.doubleValue / width.doubleValue;
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(1.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Walk up to the enclosing CellNode and trigger relayout. The host
    // MarkdownNode may not be attached to its supernodes yet (Profile
    // pre-builds cells off-screen before mounting), so we also defer a
    // relayout to onDidLoad which fires when the node is added to its
    // parent view hierarchy.
    ASDisplayNode *host = objc_getAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey);
    void (^doRelayout)(void) = ^{
        ASDisplayNode *n = host;
        ASDisplayNode *cellNode = nil;
        while (n) {
            NSString *cls = NSStringFromClass([n class]);
            if ([n respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                [n invalidateCalculatedLayout];
            }
            if ([n respondsToSelector:@selector(setNeedsLayout)]) {
                [n setNeedsLayout];
            }
            if ([cls containsString:@"CellNode"]) cellNode = n;
            n = n.supernode;
        }
        SEL relayoutSel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        id target = cellNode ?: host;
        if ([target respondsToSelector:relayoutSel]) {
            ((void (*)(id, SEL))objc_msgSend)(target, relayoutSel);
        }
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        doRelayout();
        BOOL hostMounted = [host respondsToSelector:@selector(isNodeLoaded)]
                          && [host isNodeLoaded] && host.supernode != nil;
        if (!hostMounted && [host respondsToSelector:@selector(onDidLoad:)]) {
            [host onDidLoad:^(__kindof ASDisplayNode *node) {
                dispatch_async(dispatch_get_main_queue(), doRelayout);
            }];
        }
    });

    // Multi-image albums get a "stacked card" peeking out bottom-right to
    // signal "more than one image". Installed on imageNode's view's
    // superview after relayout. Defer to onDidLoad if the imageNode
    // isn't view-loaded yet.
    NSNumber *count = [result[@"count"] respondsToSelector:@selector(integerValue)] ? result[@"count"] : nil;
    if (count.integerValue > 1) {
        __weak ASNetworkImageNode *weakImage = imageNode;
        void (^installCard)(void) = ^{
            ASNetworkImageNode *strong = weakImage;
            if (strong) ApolloInstallStackedCardForImageNode(strong);
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            ASNetworkImageNode *strong = weakImage;
            if (!strong) return;
            if ([strong respondsToSelector:@selector(isNodeLoaded)] && [strong isNodeLoaded]) {
                installCard();
            } else if ([strong respondsToSelector:@selector(onDidLoad:)]) {
                [strong onDidLoad:^(__kindof ASDisplayNode *node) {
                    dispatch_async(dispatch_get_main_queue(), installCard);
                }];
            }
        });
    }
}

// Standalone play-circle glyph (transparent background) drawn into a
// UIImageView placed over the imageNode so the play button stays visible
// no matter what the network image node renders underneath.
static UIImage *ApolloPlayOverlayImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat side = 88.0;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGPoint center = CGPointMake(side * 0.5, side * 0.5);
        CGRect circleRect = CGRectInset(CGRectMake(0, 0, side, side), 4.0, 4.0);

        // Soft dark backing so the glyph reads on bright posters.
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 6.0, [UIColor colorWithWhite:0.0 alpha:0.55].CGColor);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
        CGContextFillEllipseInRect(ctx, circleRect);
        CGContextRestoreGState(ctx);

        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.85].CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextStrokeEllipseInRect(ctx, CGRectInset(circleRect, 1.0, 1.0));

        UIBezierPath *triangle = [UIBezierPath bezierPath];
        [triangle moveToPoint:CGPointMake(center.x - 12.0, center.y - 21.0)];
        [triangle addLineToPoint:CGPointMake(center.x - 12.0, center.y + 21.0)];
        [triangle addLineToPoint:CGPointMake(center.x + 24.0, center.y)];
        [triangle closePath];
        [[UIColor whiteColor] setFill];
        [triangle fill];

        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}


// The small corner badges for tap-to-play GIFs — play triangle while paused,
// pause bars while playing. Same visual language as the video play circle,
// scaled down and consistent between the two states (both live bottom-right).
static UIImage *ApolloInlineGIFBadgeImage(BOOL pause) {
    CGFloat side = 30.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(side * 0.5, side * 0.5);
    CGRect circleRect = CGRectInset(CGRectMake(0, 0, side, side), 1.5, 1.5);

    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 3.0, [UIColor colorWithWhite:0.0 alpha:0.55].CGColor);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
    CGContextFillEllipseInRect(ctx, circleRect);
    CGContextRestoreGState(ctx);

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.85].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(circleRect, 0.75, 0.75));

    [[UIColor whiteColor] setFill];
    if (pause) {
        CGFloat barW = 3.0, barH = 11.0, gap = 5.0;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(center.x - gap * 0.5 - barW, center.y - barH * 0.5, barW, barH)
                                    cornerRadius:1.0] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(center.x + gap * 0.5, center.y - barH * 0.5, barW, barH)
                                    cornerRadius:1.0] fill];
    } else {
        // Nudged right so the triangle reads optically centered.
        UIBezierPath *triangle = [UIBezierPath bezierPath];
        [triangle moveToPoint:CGPointMake(center.x - 3.75, center.y - 6.0)];
        [triangle addLineToPoint:CGPointMake(center.x - 3.75, center.y + 6.0)];
        [triangle addLineToPoint:CGPointMake(center.x + 6.25, center.y)];
        [triangle closePath];
        [triangle fill];
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *ApolloInlineGIFPauseBadgeImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = ApolloInlineGIFBadgeImage(YES); });
    return image;
}

static UIImage *ApolloInlineGIFPlayBadgeImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = ApolloInlineGIFBadgeImage(NO); });
    return image;
}

// Overlay styles: the play affordance (bottom-right badge on paused
// tap-to-play GIFs; big centered circle on inline video posters) and the
// bottom-right pause badge (tap-to-play GIF while playing).
typedef NS_ENUM(NSInteger, ApolloInlineOverlayStyle) {
    ApolloInlineOverlayStylePlay = 0,
    ApolloInlineOverlayStylePauseBadge = 1,
};

// A UIView that positions its single subview in layoutSubviews, AND on
// every observed bounds change of its host layer. Texture sets layer
// frames directly without going through UIView's setBounds:, so neither
// autoresizingMask nor layoutSubviews fire on resize. KVO on the host
// layer's bounds is the only reliable signal.
//
// For tap-to-play GIFs the icon zone is interactive: a tap on (or near) the
// icon toggles inline playback and is swallowed there. A tap anywhere else on
// the GIF fails pointInside: and lands on the imageNode's own tap action —
// the fullscreen media viewer — so fullscreen stays reachable exactly like a
// plain image. Video-poster overlays keep userInteractionEnabled=NO: the
// whole poster opens the player, and the circle is just a visual cue.
@interface ApolloPlayOverlayContainer : UIView
@property (nonatomic, weak) CALayer *observedLayer;
@property (nonatomic, weak) ASNetworkImageNode *overlayImageNode;
@property (nonatomic) ApolloInlineOverlayStyle overlayStyle;
// GIF overlays pin the badge bottom-right (play AND pause, so the control
// sits in one consistent spot); video posters center their play circle.
@property (nonatomic) BOOL cornerPlacement;
@end
@implementation ApolloPlayOverlayContainer
- (void)layoutSubviews {
    [super layoutSubviews];
    [self recenter];
}
- (void)recenter {
    for (UIView *sub in self.subviews) {
        CGSize s = sub.bounds.size;
        if (self.cornerPlacement) {
            sub.center = CGPointMake(self.bounds.size.width - 6.0 - s.width * 0.5,
                                     self.bounds.size.height - 6.0 - s.height * 0.5);
        } else {
            sub.center = CGPointMake(self.bounds.size.width * 0.5,
                                      self.bounds.size.height * 0.5);
        }
        sub.bounds = (CGRect){CGPointZero, s};
    }
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Only the icon zone belongs to the overlay; everything else falls
    // through to the imageNode (media viewer tap, long-press menu).
    if (!self.userInteractionEnabled) return NO;
    UIView *icon = self.subviews.firstObject;
    if (!icon || icon.hidden) return NO;
    CGRect zone = icon.frame;
    CGFloat padX = MAX(0.0, (44.0 - CGRectGetWidth(zone)) * 0.5);
    CGFloat padY = MAX(0.0, (44.0 - CGRectGetHeight(zone)) * 0.5);
    return CGRectContainsPoint(CGRectInset(zone, -padX, -padY), point);
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (object == self.observedLayer) {
        CGRect b = self.observedLayer.bounds;
        self.frame = b;
        [self recenter];
    }
}
- (void)dealloc {
    [_observedLayer removeObserver:self forKeyPath:@"bounds"];
}
@end

// The overlay tap targets the dispatcher singleton, not the container
// itself — UIGestureRecognizer retains its target, so a self-targeting
// recognizer would cycle container -> recognizer -> container and leak a
// container on every play/pause style swap.
@interface ApolloInlineImageDispatcher (ApolloInlineGIFOverlay)
- (void)inlineGIFOverlayZoneTapped:(UITapGestureRecognizer *)recognizer;
@end
@implementation ApolloInlineImageDispatcher (ApolloInlineGIFOverlay)
- (void)inlineGIFOverlayZoneTapped:(UITapGestureRecognizer *)recognizer {
    ApolloPlayOverlayContainer *container = (ApolloPlayOverlayContainer *)recognizer.view;
    if (![container isKindOfClass:[ApolloPlayOverlayContainer class]]) return;
    ASNetworkImageNode *node = container.overlayImageNode;
    if (!node) return;
    if (container.overlayStyle == ApolloInlineOverlayStylePauseBadge) {
        ApolloStopInlineGIFPlayback(node);
    } else {
        ApolloStartInlineGIFPlayback(node);
    }
}
@end

// Idempotently add the play-circle overlay centered on the imageNode.
// Uses KVO on the imageNode's layer bounds since Texture mutates
// layer.frame directly (UIView setBounds: / layoutSubviews don't fire).
static void ApolloRemovePlayOverlayFromNode(ASDisplayNode *node) {
    if (!node) return;
    UIView *container = objc_getAssociatedObject(node, &kApolloPlayOverlayViewKey);
    if (!container) return;
    [container removeFromSuperview];
    objc_setAssociatedObject(node, &kApolloPlayOverlayViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloCancelInlineGIFPendingPolicyBlocks(id node) {
    if (!node) return;
    NSMutableArray<dispatch_block_t> *pending = objc_getAssociatedObject(node, &kApolloInlineGIFPendingPolicyBlocksKey);
    if (!pending) return;
    for (dispatch_block_t block in pending) {
        dispatch_block_cancel(block);
    }
    [pending removeAllObjects];
}

static void ApolloTrackInlineGIFPendingPolicyBlock(ASDisplayNode *node, dispatch_block_t block) {
    if (!node || !block) return;
    NSMutableArray<dispatch_block_t> *pending = objc_getAssociatedObject(node, &kApolloInlineGIFPendingPolicyBlocksKey);
    if (!pending) {
        pending = [NSMutableArray array];
        objc_setAssociatedObject(node, &kApolloInlineGIFPendingPolicyBlocksKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pending addObject:block];
}

static NSUInteger ApolloInlineGIFGenerationForNode(id node) {
    if (!node) return 0;
    NSNumber *generation = objc_getAssociatedObject(node, &kApolloInlineGIFGenerationKey);
    return generation ? generation.unsignedIntegerValue : 0;
}

static NSUInteger ApolloInlineGIFBumpGeneration(id node) {
    if (!node) return 0;
    NSUInteger next = ApolloInlineGIFGenerationForNode(node) + 1;
    objc_setAssociatedObject(node, &kApolloInlineGIFGenerationKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return next;
}

static BOOL ApolloInlineGIFGenerationMatches(id node, NSUInteger generation) {
    return ApolloInlineGIFGenerationForNode(node) == generation;
}

static BOOL ApolloInlineGIFAnimatedImageArgumentIsUsable(id animatedImage) {
    if (!animatedImage) return YES;
    @try {
        return object_getClass(animatedImage) != Nil;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void ApolloClearInlineGIFCoverImageReadyCallback(id anim) {
    if (!anim) return;
    if ([anim respondsToSelector:@selector(setCoverImageReadyCallback:)]) {
        [anim performSelector:@selector(setCoverImageReadyCallback:) withObject:nil];
    }
}

static void ApolloClearInlineGIFNodeState(ASNetworkImageNode *node) {
    if (!node) return;
    ApolloInlineGIFBumpGeneration(node);
    ApolloCancelInlineGIFPendingPolicyBlocks(node);
    id anim = objc_getAssociatedObject(node, &kApolloInlineGIFAnimatedImageKey);
    ApolloClearInlineGIFCoverImageReadyCallback(anim);
    ApolloRemovePlayOverlayFromNode(node);
    objc_setAssociatedObject(node, &kApolloInlineGIFAnimatedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloInlineGIFCoverImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloInlineAnimatedGIFKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloInlineGIFUserForcedPlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloInlineGIFOverlayReassertKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloHostMarkdownNodeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    ApolloUnregisterInlineGIFNode(node);
}

// kApolloHostMarkdownNodeKey uses OBJC_ASSOCIATION_ASSIGN — never read that host
// pointer during settings refresh; it can dangle after cell reuse while the slot stays non-nil.
static BOOL ApolloInlineGIFImageNodeIsLiveForRefresh(ASNetworkImageNode *node) {
    if (!ApolloInlineGIFNodeIsRegistryEligible(node)) {
        if (node) ApolloUnregisterInlineGIFNode(node);
        ApolloLog(@"[AutoplayGIF] live-check node=%p ineligible", node);
        return NO;
    }
    if (!node) return NO;
    if (![objc_getAssociatedObject(node, &kApolloInlineAnimatedGIFKey) boolValue]) {
        ApolloUnregisterInlineGIFNode(node);
        ApolloLog(@"[AutoplayGIF] live-check node=%p no-anim-flag", node);
        return NO;
    }
    @try {
        if (![node respondsToSelector:@selector(isNodeLoaded)] || ![node isNodeLoaded]) {
            ApolloLog(@"[AutoplayGIF] live-check node=%p not-loaded", node);
            return NO;
        }
        if (!node.supernode) {
            ApolloUnregisterInlineGIFNode(node);
            ApolloLog(@"[AutoplayGIF] live-check node=%p no-supernode", node);
            return NO;
        }
        // Deliberately no node.URL requirement: the tweak's GIF pipeline loads
        // through its own downloader and never sets the node URL, so a URL
        // check disqualified every hosted GIF from settings-refresh handling.
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[AutoplayGIF] live-check failed node=%p class=%@ reason=%@",
                  node, NSStringFromClass([node class]), exception.reason);
        ApolloUnregisterInlineGIFNode(node);
        return NO;
    }
}

// Idempotently attach the requested overlay style; swaps in place when the
// node transitions between paused (play button) and user-playing (pause
// badge). Stored under kApolloPlayOverlayViewKey so every existing removal
// path (clear state, cell reuse, settings refresh) cleans up either style.
static void ApolloInstallOverlayWithStyleOnView(UIView *v, ASDisplayNode *node, ApolloInlineOverlayStyle style) {
    if (!v || !node) return;
    ApolloPlayOverlayContainer *existing = objc_getAssociatedObject(node, &kApolloPlayOverlayViewKey);
    if (existing) {
        if ([existing isKindOfClass:[ApolloPlayOverlayContainer class]] &&
            existing.overlayStyle == style && existing.superview == v) {
            return;
        }
        ApolloRemovePlayOverlayFromNode(node);
    }

    ApolloPlayOverlayContainer *container = [[ApolloPlayOverlayContainer alloc] initWithFrame:v.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.overlayStyle = style;
    container.overlayImageNode = (ASNetworkImageNode *)node;

    // Only tap-to-play GIFs get the interactive icon zone. Video posters
    // (no inline-GIF flag) stay pure visuals — the whole poster is the tap
    // target for the player, exactly as before.
    BOOL gifTapToPlay = [objc_getAssociatedObject(node, &kApolloInlineAnimatedGIFKey) boolValue];
    container.userInteractionEnabled = gifTapToPlay;
    container.cornerPlacement = gifTapToPlay;
    if (gifTapToPlay) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:[ApolloInlineImageDispatcher shared]
                    action:@selector(inlineGIFOverlayZoneTapped:)];
        [container addGestureRecognizer:tap];
    }

    // GIF overlays: play and pause are the SAME small bottom-right badge so
    // the control sits in one consistent spot and never covers the artwork.
    // Video posters keep the big centered play circle.
    BOOL badge = (style == ApolloInlineOverlayStylePauseBadge);
    UIImage *iconImage;
    CGRect iconFrame;
    if (gifTapToPlay) {
        iconImage = badge ? ApolloInlineGIFPauseBadgeImage() : ApolloInlineGIFPlayBadgeImage();
        iconFrame = CGRectMake(0, 0, 30, 30);
    } else {
        iconImage = ApolloPlayOverlayImage();
        iconFrame = CGRectMake(0, 0, 72, 72);
    }
    UIImageView *icon = [[UIImageView alloc] initWithImage:iconImage];
    icon.userInteractionEnabled = NO;
    icon.frame = iconFrame;
    [container addSubview:icon];

    [v addSubview:container];
    [v bringSubviewToFront:container];

    // Observe the host layer's bounds — fires whenever Texture re-lays out
    // the node, including the initial size assignment.
    container.observedLayer = v.layer;
    [v.layer addObserver:container forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:NULL];
    [container recenter];

    objc_setAssociatedObject(node, &kApolloPlayOverlayViewKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // GIF overlays get the same detach-heal as video posters: an async
    // relayout-from-above (cover sizing, metadata rebuild) can recycle the
    // backing view and silently drop the container — and with it the only
    // inline play/pause tap zone. One pending sequence per node.
    if (gifTapToPlay &&
        ![objc_getAssociatedObject(node, &kApolloInlineGIFOverlayReassertKey) boolValue]) {
        objc_setAssociatedObject(node, &kApolloInlineGIFOverlayReassertKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSchedulePlayOverlayReassert((ASNetworkImageNode *)node, 0);
    }
}

static void ApolloInstallPlayOverlayOnView(UIView *v, ASDisplayNode *node) {
    ApolloInstallOverlayWithStyleOnView(v, node, ApolloInlineOverlayStylePlay);
}

// Single source of truth mapping a hosted inline GIF's state to its overlay:
//   autoplaying globally                       -> none (tap opens the viewer)
//   paused + Tap to Play / blocked WiFi Only   -> corner play badge
//   user-started playback (forced play)        -> corner pause badge
//   paused + Never                             -> none (pure static cover)
static void ApolloUpdateInlineGIFOverlayForNode(ASDisplayNode *node) {
    if (!node) return;
    if (![objc_getAssociatedObject(node, &kApolloInlineAnimatedGIFKey) boolValue]) return;
    if (![node respondsToSelector:@selector(isNodeLoaded)] || ![node isNodeLoaded]) return;
    UIView *view = [node view];
    if (!view) return;
    if (ApolloShouldAutoplayInlineGIFCached() || !ApolloPausedInlineGIFWantsPlayOverlay()) {
        ApolloRemovePlayOverlayFromNode(node);
        return;
    }
    BOOL forced = [objc_getAssociatedObject(node, &kApolloInlineGIFUserForcedPlayKey) boolValue];
    ApolloInstallOverlayWithStyleOnView(view, node,
        forced ? ApolloInlineOverlayStylePauseBadge : ApolloInlineOverlayStylePlay);
}

// The play overlay is first added in onDidLoad while the node still has
// zero bounds, then relies on KVO to recenter once Texture assigns the
// real frame. Two things break that for inline video thumbnails AND
// tap-to-play GIF overlays:
//   1. When an async resolve (DASH poster, GIF cover sizing, metadata
//      rebuild) triggers a relayout-from-above, Texture can recycle the
//      node's backing view and silently drop our manually-added overlay
//      subview (the association still points at the now-detached container).
//   2. If the very first layout pass already gave the node real bounds,
//      the KVO "new bounds" notification may have fired before the overlay
//      was attached.
// Re-assert the overlay a few times after install so it survives view
// recycling and late sizing. Idempotent when the overlay is already
// correctly attached. GIF nodes re-derive their overlay from state (play
// button vs pause badge vs none); video posters reinstall the play circle.
static void ApolloSchedulePlayOverlayReassertMode(ASNetworkImageNode *imageNode, NSUInteger attempt, BOOL forGIF) {
    static const NSTimeInterval delays[] = {0.10, 0.25, 0.50, 1.0, 1.75, 2.5};
    static const NSUInteger maxAttempts = sizeof(delays) / sizeof(delays[0]);
    if (!imageNode) return;
    if (attempt >= maxAttempts) {
        if (forGIF) {
            objc_setAssociatedObject(imageNode, &kApolloInlineGIFOverlayReassertKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    __weak ASNetworkImageNode *weak = imageNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ASNetworkImageNode *node = weak;
        if (!node) return;
        if (forGIF && ![objc_getAssociatedObject(node, &kApolloInlineAnimatedGIFKey) boolValue]) {
            // The node was cleared/reused since this sequence was scheduled —
            // stop; whatever the node shows now, it isn't our GIF anymore.
            objc_setAssociatedObject(node, &kApolloInlineGIFOverlayReassertKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        BOOL loaded = [node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded];
        UIView *view = loaded ? [node view] : nil;
        if (view) {
            UIView *overlay = objc_getAssociatedObject(node, &kApolloPlayOverlayViewKey);
            BOOL stale = overlay && overlay.superview != view;
            if (stale) {
                // Association points at a recycled/detached view — drop it
                // and reinstall onto the live view.
                [overlay removeFromSuperview];
                objc_setAssociatedObject(node, &kApolloPlayOverlayViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                overlay = nil;
            }
            if (!overlay) {
                if (forGIF) {
                    ApolloUpdateInlineGIFOverlayForNode(node);
                } else {
                    ApolloInstallPlayOverlayOnView(view, node);
                }
            } else {
                [view bringSubviewToFront:overlay];
                if ([overlay isKindOfClass:[ApolloPlayOverlayContainer class]]) {
                    [(ApolloPlayOverlayContainer *)overlay recenter];
                }
            }
        }
        ApolloSchedulePlayOverlayReassertMode(node, attempt + 1, forGIF);
    });
}

static void ApolloSchedulePlayOverlayReassert(ASNetworkImageNode *imageNode, NSUInteger attempt) {
    ApolloSchedulePlayOverlayReassertMode(imageNode, attempt,
        [objc_getAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey) boolValue]);
}

// Pause inline GIF playback without clearing animatedImage via KVC — that path
// races with Texture teardown during AutoplayGIFs preference changes and caused
// SIGSEGV in _locked_setAnimatedImage on stale nodes.
static void ApolloPauseInlineGIFNode(ASNetworkImageNode *imageNode, UIImage *cover) {
    if (!imageNode) return;
    if (![objc_getAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;

    objc_setAssociatedObject(imageNode, &kApolloInlineGIFUserForcedPlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
    if (view) {
        ApolloMarkViewAsInlineGIF(view);
        ApolloSetInlineGIFUserForcedPlay(view, NO);
        UIView *animView = ApolloFindFLAnimatedImageViewInView(view);
        if (animView) {
            ApolloApplyFLAnimatedImageViewAutoplayGate(animView);
        }
    }
    // Also halt Texture's own animated-image display in case this node's GIF
    // renders through the PIN pipeline rather than an FLAnimatedImageView.
    if ([imageNode respondsToSelector:@selector(setAnimatedImagePaused:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(imageNode, @selector(setAnimatedImagePaused:), YES);
    }

    if (cover && cover.size.width > 0 && [imageNode respondsToSelector:@selector(setImage:)]) {
        // setImage: makes Texture clear the node's animatedImage, which fires
        // our _locked_setAnimatedImage:(nil) hook. Without the in-flight flag
        // that scheduled ApolloClearInlineGIFNodeState — silently wiping the
        // GIF flag, removing the play overlay, and unregistering the node the
        // moment it was paused (so taps opened the viewer instead of playing
        // inline, and settings refreshes found nothing to resume).
        objc_setAssociatedObject(imageNode, &kApolloInlineGIFReloadInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [imageNode setImage:cover];
        objc_setAssociatedObject(imageNode, &kApolloInlineGIFReloadInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Never mode is a pure static cover — tap falls through to the normal
    // image tap (media viewer). Tap to Play / blocked WiFi Only get the
    // inline play button (forced-play was cleared above, so never a badge).
    ApolloUpdateInlineGIFOverlayForNode(imageNode);
}

BOOL ApolloPauseInlineGIFNodeForAutoplay(id imageNode) {
    if (!ApolloInlineGIFNodeIsRegistryEligible(imageNode)) {
        if (imageNode) ApolloUnregisterInlineGIFNode(imageNode);
        return NO;
    }
    ASNetworkImageNode *node = (ASNetworkImageNode *)imageNode;
    if (!ApolloInlineGIFImageNodeIsLiveForRefresh(node)) return NO;
    UIImage *cover = objc_getAssociatedObject(node, &kApolloInlineGIFCoverImageKey);
    @try {
        ApolloPauseInlineGIFNode(node, cover);
    } @catch (NSException *exception) {
        ApolloLog(@"[AutoplayGIF] pause failed node=%p class=%@ reason=%@",
                  node, NSStringFromClass([node class]), exception.reason);
        ApolloUnregisterInlineGIFNode(node);
        return NO;
    }
    return YES;
}

BOOL ApolloReloadInlineGIFImageNodeForAutoplay(id imageNode) {
    if (!ApolloInlineGIFNodeIsRegistryEligible(imageNode)) {
        if (imageNode) ApolloUnregisterInlineGIFNode(imageNode);
        return NO;
    }
    ASNetworkImageNode *node = (ASNetworkImageNode *)imageNode;
    if (!ApolloInlineGIFImageNodeIsLiveForRefresh(node)) return NO;

    ApolloRemovePlayOverlayFromNode(node);
    if (ApolloResumeInlineGIFPlaybackIfPossible(node)) {
        ApolloLog(@"[AutoplayGIF] resume-only node=%p", node);
        return NO;
    }
    // No live FLAnimatedImageView to resume (the pause's cover swap tears the
    // playback state down) — re-inject the retained animated image, same as
    // tap-to-play. The tweak's GIF pipeline doesn't set node.URL, so a URL
    // round trip usually isn't available.
    id storedAnim = objc_getAssociatedObject(node, &kApolloInlineGIFAnimatedImageKey);
    if (storedAnim && [node respondsToSelector:@selector(setAnimatedImage:)]) {
        @try {
            [(id)node setAnimatedImage:storedAnim];
        } @catch (NSException *exception) {
            ApolloLog(@"[AutoplayGIF] reload reinject failed node=%p reason=%@", node, exception.reason);
            ApolloUnregisterInlineGIFNode(node);
            return NO;
        }
        ApolloLog(@"[AutoplayGIF] reload reinject node=%p", node);
        return YES;
    }

    if (![node respondsToSelector:@selector(setURL:)] ||
        ![node respondsToSelector:@selector(URL)]) {
        ApolloUnregisterInlineGIFNode(node);
        return NO;
    }

    NSURL *url = [[node URL] copy];
    if (!url) return NO;

    ApolloCancelInlineGIFPendingPolicyBlocks(node);
    ApolloInlineGIFBumpGeneration(node);
    objc_setAssociatedObject(node, &kApolloInlineGIFUserForcedPlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // This AsyncDisplayKit build has no -clearImage; reset through the URL
    // round trip (setURL:nil clears image + animatedImage internally). The
    // in-flight flag keeps our setURL:/_locked_setAnimatedImage hooks from
    // clearing the node's inline-GIF state during the reset.
    objc_setAssociatedObject(node, &kApolloInlineGIFReloadInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL reloadOK = YES;
    @try {
        if ([node respondsToSelector:@selector(setImage:)]) [node setImage:nil];
        [node setURL:nil];
        [node setURL:url];
    } @catch (NSException *exception) {
        ApolloLog(@"[AutoplayGIF] reload failed node=%p class=%@ reason=%@",
                  node, NSStringFromClass([node class]), exception.reason);
        reloadOK = NO;
    }
    objc_setAssociatedObject(node, &kApolloInlineGIFReloadInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!reloadOK) {
        ApolloUnregisterInlineGIFNode(node);
        return NO;
    }
    ApolloLog(@"[AutoplayGIF] reload node=%p url=%@", node, url.host ?: url.absoluteString);
    return YES;
}

static void ApolloApplyInlineGIFPlaybackPolicyWithCover(ASNetworkImageNode *imageNode, UIImage *cover, NSUInteger retryIndex) {
    if (!imageNode) return;
    if (![objc_getAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;

    if (retryIndex == 0) {
        ApolloCancelInlineGIFPendingPolicyBlocks(imageNode);
    }

    if (cover && cover.size.width > 0 && cover.size.height > 0) {
        objc_setAssociatedObject(imageNode, &kApolloInlineGIFCoverImageKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        UIImage *storedCover = objc_getAssociatedObject(imageNode, &kApolloInlineGIFCoverImageKey);
        if ([storedCover isKindOfClass:[UIImage class]] && storedCover.size.width > 0 && storedCover.size.height > 0) {
            cover = storedCover;
        }
    }

    static const NSTimeInterval kRetryDelays[] = {0.016, 0.050};

    NSUInteger capturedGeneration = ApolloInlineGIFGenerationForNode(imageNode);
    __weak ASNetworkImageNode *weakNode = imageNode;
    __block dispatch_block_t block = nil;
    block = dispatch_block_create((dispatch_block_flags_t)0, ^{
        if (dispatch_block_testcancel(block)) return;
        ASNetworkImageNode *strong = weakNode;
        if (!strong || !ApolloInlineGIFGenerationMatches(strong, capturedGeneration)) return;
        if (![objc_getAssociatedObject(strong, &kApolloInlineAnimatedGIFKey) boolValue]) return;
        if (![strong respondsToSelector:@selector(isNodeLoaded)] || ![strong isNodeLoaded]) {
            if (retryIndex < 3) {
                NSTimeInterval delay = (retryIndex == 0) ? 0.0 : kRetryDelays[retryIndex - 1];
                if (delay > 0.0) {
                    __weak ASNetworkImageNode *weakRetry = strong;
                    __block dispatch_block_t retryBlock = nil;
                    retryBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                        if (dispatch_block_testcancel(retryBlock)) return;
                        ASNetworkImageNode *retryNode = weakRetry;
                        if (!retryNode || !ApolloInlineGIFGenerationMatches(retryNode, capturedGeneration)) return;
                        if (![objc_getAssociatedObject(retryNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;
                        ApolloApplyInlineGIFPlaybackPolicyWithCover(retryNode, cover, retryIndex + 1);
                    });
                    ApolloTrackInlineGIFPendingPolicyBlock(strong, retryBlock);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), retryBlock);
                } else {
                    ApolloApplyInlineGIFPlaybackPolicyWithCover(strong, cover, retryIndex + 1);
                }
            } else if ([strong respondsToSelector:@selector(onDidLoad:)]) {
                __weak ASNetworkImageNode *weakLoad = strong;
                [strong onDidLoad:^(__kindof ASDisplayNode *node) {
                    if (![objc_getAssociatedObject(node, &kApolloInlineAnimatedGIFKey) boolValue]) return;
                    if (weakLoad && node != weakLoad) return;
                    UIImage *storedCover = objc_getAssociatedObject(node, &kApolloInlineGIFCoverImageKey);
                    ApolloApplyInlineGIFPlaybackPolicyWithCover((ASNetworkImageNode *)node, storedCover, 0);
                }];
            }
            return;
        }

        UIView *view = [strong view];
        if (!view) return;
        ApolloMarkViewAsInlineGIF(view);

        BOOL forcedPlay = [objc_getAssociatedObject(strong, &kApolloInlineGIFUserForcedPlayKey) boolValue];
        BOOL shouldPlay = forcedPlay || ApolloShouldAutoplayInlineGIFCached();

        if (shouldPlay) {
            ApolloUpdateInlineGIFOverlayForNode(strong);
            if (ApolloResumeInlineGIFPlaybackIfPossible(strong)) {
                ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu shouldPlay=1 resume=1 forced=%d",
                          strong, (unsigned long)retryIndex, forcedPlay);
                return;
            }
            // FLAnimatedImageView may not exist yet on freshly posted comments —
            // retry without re-storing a cached animatedImage pointer (scroll crash).
            if (retryIndex < 5) {
                NSTimeInterval delay = (retryIndex == 0) ? 0.016 : kRetryDelays[MIN(retryIndex - 1, 1)];
                __weak ASNetworkImageNode *weakRetry = strong;
                __block dispatch_block_t retryBlock = nil;
                retryBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                    if (dispatch_block_testcancel(retryBlock)) return;
                    ASNetworkImageNode *retryNode = weakRetry;
                    if (!retryNode || !ApolloInlineGIFGenerationMatches(retryNode, capturedGeneration)) return;
                    if (![objc_getAssociatedObject(retryNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;
                    ApolloApplyInlineGIFPlaybackPolicyWithCover(retryNode, cover, retryIndex + 1);
                });
                ApolloTrackInlineGIFPendingPolicyBlock(strong, retryBlock);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), retryBlock);
                ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu shouldPlay=1 resume=0 scheduling=%lu forced=%d",
                          strong, (unsigned long)retryIndex, (unsigned long)(retryIndex + 1), forcedPlay);
                return;
            }
            ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu shouldPlay=1 resume=0 forced=%d",
                      strong, (unsigned long)retryIndex, forcedPlay);
            return;
        }

        if (cover) {
            ApolloPauseInlineGIFNode(strong, cover);
            ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu staticCover=1 shouldPlay=0",
                      strong, (unsigned long)retryIndex);
            return;
        }

        // Cover not ready yet — retry instead of clearing animatedImage to a blank box.
        if (retryIndex < 5) {
            NSTimeInterval delay = (retryIndex == 0) ? 0.050 : kRetryDelays[MIN(retryIndex - 1, 1)];
            __weak ASNetworkImageNode *weakRetry = strong;
            __block dispatch_block_t retryBlock = nil;
            retryBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                if (dispatch_block_testcancel(retryBlock)) return;
                ASNetworkImageNode *retryNode = weakRetry;
                if (!retryNode || !ApolloInlineGIFGenerationMatches(retryNode, capturedGeneration)) return;
                if (![objc_getAssociatedObject(retryNode, &kApolloInlineAnimatedGIFKey) boolValue]) return;
                UIImage *storedCover = objc_getAssociatedObject(retryNode, &kApolloInlineGIFCoverImageKey);
                ApolloApplyInlineGIFPlaybackPolicyWithCover(retryNode, storedCover, retryIndex + 1);
            });
            ApolloTrackInlineGIFPendingPolicyBlock(strong, retryBlock);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), retryBlock);
            ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu waitingForCover=%lu shouldPlay=0",
                      strong, (unsigned long)retryIndex, (unsigned long)(retryIndex + 1));
            return;
        }

        ApolloPauseInlineGIFNode(strong, nil);
        ApolloLog(@"[AutoplayGIF] policy node=%p retry=%lu pausedNoCover=1 shouldPlay=0",
                  strong, (unsigned long)retryIndex);
    });
    ApolloTrackInlineGIFPendingPolicyBlock(imageNode, block);
    dispatch_async(dispatch_get_main_queue(), block);
}

static BOOL ApolloResumeInlineGIFPlaybackIfPossible(ASNetworkImageNode *imageNode) {
    if (!imageNode) return NO;
    if (![objc_getAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey) boolValue]) return NO;

    UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
    if (!view) return NO;

    // Mirror of the pause path: release Texture's animated-image pause in case
    // this node's GIF renders through the PIN pipeline.
    if ([imageNode respondsToSelector:@selector(setAnimatedImagePaused:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(imageNode, @selector(setAnimatedImagePaused:), NO);
    }

    UIView *animView = ApolloFindFLAnimatedImageViewInView(view);
    if (!animView) return NO;

    // The pause's cover swap makes Texture drop the view's animatedImage —
    // with no animation data "resuming" would just leave the cover frozen.
    // Report NO so callers fall back to re-injecting/reloading the GIF.
    id currentAnim = nil;
    @try {
        if ([animView respondsToSelector:@selector(animatedImage)]) {
            currentAnim = [animView valueForKey:@"animatedImage"];
        }
    } @catch (__unused NSException *exception) {}
    if (!currentAnim) return NO;

    BOOL forcedPlay = [objc_getAssociatedObject(imageNode, &kApolloInlineGIFUserForcedPlayKey) boolValue];
    if (forcedPlay) ApolloSetInlineGIFUserForcedPlay(animView, YES);
    ApolloApplyFLAnimatedImageViewAutoplayGate(animView);
    // Autoplay resume drops the overlay; a user-forced (tap-to-play) resume
    // swaps the play button for the corner pause badge.
    ApolloUpdateInlineGIFOverlayForNode(imageNode);
    ApolloLog(@"[AutoplayGIF] resume node=%p animView=%p forced=%d", imageNode, animView, forcedPlay);
    return YES;
}

static void ApolloStartInlineGIFPlayback(ASNetworkImageNode *imageNode) {
    if (!imageNode) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(imageNode, &kApolloInlineGIFUserForcedPlayKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *view = [imageNode respondsToSelector:@selector(view)] ? [imageNode view] : nil;
        if (view) ApolloSetInlineGIFUserForcedPlay(view, YES);

        if (ApolloResumeInlineGIFPlaybackIfPossible(imageNode)) {
            ApolloLog(@"[AutoplayGIF] userPlay node=%p resume=1", imageNode);
            return;
        }

        // Forced-play was set above — this swaps the play button for the
        // corner pause badge right away, before the re-inject lands.
        ApolloUpdateInlineGIFOverlayForNode(imageNode);

        // Nothing to resume — the pause's cover swap made Texture drop its
        // animatedImage. Re-inject the retained copy; that re-runs the
        // _locked_setAnimatedImage flow, and the playback policy honors the
        // forced-play flag set above.
        id storedAnim = objc_getAssociatedObject(imageNode, &kApolloInlineGIFAnimatedImageKey);
        if (storedAnim && [imageNode respondsToSelector:@selector(setAnimatedImage:)]) {
            @try {
                [(id)imageNode setAnimatedImage:storedAnim];
                ApolloLog(@"[AutoplayGIF] userPlay node=%p reinject=1", imageNode);
                return;
            } @catch (NSException *exception) {
                ApolloLog(@"[AutoplayGIF] userPlay reinject failed node=%p reason=%@", imageNode, exception.reason);
            }
        }

        ApolloApplyInlineGIFPlaybackPolicyWithCover(imageNode, nil, 0);
        ApolloLog(@"[AutoplayGIF] userPlay node=%p resume=0 policy=1", imageNode);
    });
}

// Tap on the corner pause badge of a playing tap-to-play GIF: pause it back
// to the static cover + play button. ApolloPauseInlineGIFNode clears the
// forced-play flags, halts both animation pipelines, swaps the cover in, and
// re-installs the overlay per the current mode — so the next tap plays again.
static void ApolloStopInlineGIFPlayback(ASNetworkImageNode *imageNode) {
    if (!imageNode) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImage *cover = objc_getAssociatedObject(imageNode, &kApolloInlineGIFCoverImageKey);
        ApolloPauseInlineGIFNode(imageNode, cover);
        ApolloLog(@"[AutoplayGIF] userPause node=%p cover=%d", imageNode, cover != nil);
    });
}

// "Stacked card" view shown behind a multi-image album thumbnail. Peeks
// out from the top-right of the imageNode (same size, offset +8pt right
// / -8pt up), in systemGray3Color for contrast against any cell
// background in both light and dark themes. Gives a visual cue that the
// album has more than one image without loading any additional images.
//
// Sibling to imageNode.view in the parent (MarkdownNode's view) rather
// than a subview — imageNode.clipsToBounds=YES would clip the peek.
// KVO on imageNode.layer.bounds/position keeps the card frame in sync
// across Texture layout passes (which mutate layer.frame directly).
static const CGFloat kApolloStackedCardOffset = 8.0;

@interface ApolloStackedCardSyncer : NSObject
@property (nonatomic, weak) UIView *card;
@property (nonatomic, weak) UIView *anchor;
@end
@implementation ApolloStackedCardSyncer
- (void)syncFrame {
    UIView *anchor = self.anchor;
    UIView *card = self.card;
    if (!anchor || !card) return;
    CGRect a = anchor.frame;
    if (CGRectIsEmpty(a)) return;
    card.frame = CGRectMake(a.origin.x + kApolloStackedCardOffset,
                             a.origin.y - kApolloStackedCardOffset,
                             a.size.width,
                             a.size.height);
    // Texture may re-add the imageNode's view to the parent during
    // layout passes, which can flip z-order. Re-assert "card below
    // image" on every sync.
    UIView *parent = anchor.superview;
    if (parent == card.superview) {
        [parent insertSubview:card belowSubview:anchor];
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    [self syncFrame];
}
- (void)dealloc {
    UIView *anchor = _anchor;
    if (anchor) {
        @try { [anchor.layer removeObserver:self forKeyPath:@"bounds"]; } @catch (__unused NSException *e) {}
        @try { [anchor.layer removeObserver:self forKeyPath:@"position"]; } @catch (__unused NSException *e) {}
    }
}
@end

static void ApolloInstallStackedCardForImageNode(ASNetworkImageNode *imageNode) {
    if (objc_getAssociatedObject(imageNode, &kApolloStackedCardSyncerKey)) return;
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)] || ![imageNode isNodeLoaded]) return;
    UIView *imgView = [imageNode view];
    UIView *parent = imgView.superview;
    if (!imgView || !parent) return;

    UIView *card = [[UIView alloc] init];
    card.userInteractionEnabled = NO;
    card.backgroundColor = [UIColor systemGray3Color];
    card.layer.cornerRadius = 8.0;
    [parent insertSubview:card belowSubview:imgView];

    ApolloStackedCardSyncer *syncer = [ApolloStackedCardSyncer new];
    syncer.card = card;
    syncer.anchor = imgView;
    [syncer syncFrame];
    [imgView.layer addObserver:syncer forKeyPath:@"bounds" options:0 context:NULL];
    [imgView.layer addObserver:syncer forKeyPath:@"position" options:0 context:NULL];
    objc_setAssociatedObject(imageNode, &kApolloStackedCardSyncerKey, syncer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Builds a video thumbnail with a 16:9 placeholder ratio so it's included
// in layout immediately, then resolves the real poster URL + ratio
// asynchronously in didLoad (after Texture connects the supernode chain).
static ASNetworkImageNode *ApolloMakeInlineVideoThumbnailNode(NSURL *videoURL,
                                                               ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.shouldRenderProgressImages = YES;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.placeholderColor = [UIColor tertiarySystemFillColor];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    imageNode.borderWidth = 0.0;
    imageNode.delegate = [ApolloInlineImageDispatcher shared];

    [imageNode addTarget:[ApolloInlineImageDispatcher shared]
                  action:@selector(imageNodeTapped:)
        forControlEvents:ApolloASControlNodeEventTouchUpInside];

    [[imageNode style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    // Tap routes to the MP4 URL (MediaViewer plays video). Default 16:9
    // ratio so the layout reserves space immediately; DIDLOAD refines it
    // once the real poster loads.
    objc_setAssociatedObject(imageNode, &kApolloImageURLKey, videoURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(9.0 / 16.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak ASNetworkImageNode *weakImage = imageNode;
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        UIView *v = [img view];

        // Resolve the poster now that the supernode chain is connected
        // (MarkdownNode → ... → CommentCellNode/CommentsHeaderCellNode).
        // Try the cheap signed-thumbnail URL first; if not available
        // (RedditVideo entries have no p[]), fall back to DASH manifest
        // + AVAssetImageGenerator to extract a frame at t=0.
        if (!img.URL && !img.image) {
            ASDisplayNode *host = objc_getAssociatedObject(img, &kApolloHostMarkdownNodeKey);
            NSDictionary *mm = ApolloMediaMetadataForHost(host);
            NSURL *posterURL = mm ? ApolloPosterURLFromMediaMetadata(mm, videoURL) : nil;
            if (posterURL) {
                img.URL = posterURL;
            } else {
                NSURL *dashURL = mm ? ApolloDashURLFromMediaMetadata(mm, videoURL) : nil;
                NSString *assetID = ApolloMediaMetadataIDFromVideoURL(videoURL);
                // Fallback when mediaMetadata isn't reachable up the supernode
                // chain (a timing race on first layout that leaves hostMD=nil):
                // Reddit hosted-video permalinks expose a stable DASH manifest
                // at v.redd.it/<assetID>/DASHPlaylist.mpd. Deriving it directly
                // from the asset id lets the poster — and the play-button
                // overlay, which only becomes visible once the node has real
                // bounds — resolve without metadata.
                if (!dashURL && assetID.length) {
                    NSString *host = [[videoURL host] lowercaseString] ?: @"";
                    NSString *path = [[videoURL path] lowercaseString] ?: @"";
                    BOOL isRedditPlayer = ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])
                        && [path hasPrefix:@"/link/"] && [path containsString:@"/video/"] && [path hasSuffix:@"/player"];
                    if (isRedditPlayer) {
                        dashURL = [NSURL URLWithString:[NSString stringWithFormat:
                            @"https://v.redd.it/%@/DASHPlaylist.mpd", assetID]];
                    }
                }
                if (dashURL && assetID.length) {
                    ApolloFetchDashPoster(assetID, dashURL, ^(UIImage *poster) {
                        ASNetworkImageNode *strong = weakImage;
                        if (!strong) return;
                        if (poster) {
                            strong.image = poster;
                            if (poster.size.width > 0 && poster.size.height > 0) {
                                [[ApolloInlineImageDispatcher shared]
                                    updateAspectRatioForImageNode:strong imageSize:poster.size];
                            }
                        } else if (!strong.image && !strong.URL) {
                            strong.backgroundColor = [UIColor tertiarySystemFillColor];
                        }
                    });
                } else {
                    ApolloLog(@"[InlineImages] video poster NOT FOUND node=%p video=%@", img, videoURL);
                    img.backgroundColor = [UIColor tertiarySystemFillColor];
                }
            }
        }

        if (v) ApolloInstallPlayOverlayOnView(v, img);
        ApolloSchedulePlayOverlayReassert(img, 0);
        if (v && ![objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) {
            NSURL *u = objc_getAssociatedObject(img, &kApolloImageURLKey);
            objc_setAssociatedObject(v, &kApolloImageURLKey, u, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
                initWithDelegate:[ApolloInlineImageDispatcher shared]];
            [v addInteraction:menu];
            objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];

    return imageNode;
}

static ASNetworkImageNode *ApolloMakeInlineImageNode(NSURL *normalizedURL,
                                                      ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    // Imgur/ImageChest album URLs need an API roundtrip or page fetch to resolve to a
    // renderable image. Defer setting imageNode.URL until resolution
    // completes — otherwise PINRemoteImage tries to fetch the album
    // page HTML as an image.
    BOOL deferredImgur = ApolloIsImgurAlbumOrGalleryURL(normalizedURL);
    BOOL deferredImageChest = ApolloImageChestIsPostURL(normalizedURL);
    BOOL deferredAlbum = deferredImgur || deferredImageChest;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    if (!deferredAlbum) {
        imageNode.URL = normalizedURL;
    }
    imageNode.shouldRenderProgressImages = YES;
    // aspectFit always: container ratio may be clamped (very tall/wide
    // images) or guessed when ratio is unknown — fit avoids cropping in
    // both cases. When ratios match, fit and fill render identically.
    imageNode.contentMode = UIViewContentModeScaleAspectFit;
    imageNode.placeholderColor = [UIColor colorWithWhite:0.5 alpha:0.12];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    // Border is set per-layout in ApolloWrapImageNodeForLayout (only when
    // letterboxed). Initialize off; the wrapper toggles per pass.
    imageNode.borderWidth = 0.0;
    imageNode.delegate = [ApolloInlineImageDispatcher shared];

    // Tap → ASControlNode TouchUpInside. ASNetworkImageNode IS-A ASControlNode
    // and is view-backed by default, so this fires correctly. (The byline/
    // meta-row layer-backed addTarget no-op gotcha in AGENTS.md applies to
    // PostInfoNode children, not to MarkdownNode subnodes.)
    [imageNode addTarget:[ApolloInlineImageDispatcher shared]
                  action:@selector(imageNodeTapped:)
        forControlEvents:ApolloASControlNodeEventTouchUpInside];

    [[imageNode style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    CGFloat ratio = ApolloAspectRatioFromURL(normalizedURL);
    // kApolloAspectRatioKey is only set when we have real ratio info (URL
    // query params now, or didLoadImage later). Nil means "unknown" → the
    // wrapper omits the image from layout to avoid wrong-ratio races.

    // Stable cache key — the per-MarkdownNode reuse cache and the GC
    // both key on this. For Imgur albums the loaded URL changes when
    // resolution completes, so we can't use imageNode.URL.
    objc_setAssociatedObject(imageNode, &kApolloImageCacheKey, normalizedURL.absoluteString, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!deferredAlbum) {
        objc_setAssociatedObject(imageNode, &kApolloImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // For album URLs, record the album URL as "original" so
        // copy/share/open actions keep what the user posted.
        objc_setAssociatedObject(imageNode, &kApolloOriginalImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    if (ratio > 0) {
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Kick off Imgur/ImageChest album resolution. Result is applied
    // asynchronously via ApolloApplyResolvedAlbumImage, which sets the
    // load URL, captures aspect ratio, and triggers cell relayout.
    __weak ASNetworkImageNode *weakImage = imageNode;
    if (deferredImgur) {
        ApolloResolveImgurURL(normalizedURL, ^(NSDictionary *result) {
            ASNetworkImageNode *strong = weakImage;
            if (!strong || !result) return;
            ApolloApplyResolvedAlbumImage(strong, result);
        });
    } else if (deferredImageChest) {
        NSDictionary *cached = ApolloImageChestCachedResolution(normalizedURL);
        if (cached) {
            ApolloApplyResolvedAlbumImage(imageNode, cached);
        } else {
            ApolloImageChestResolveURL(normalizedURL, ^(NSDictionary *result) {
                ASNetworkImageNode *strong = weakImage;
                if (!strong || !result) return;
                ApolloApplyResolvedAlbumImage(strong, result);
            });
        }
    }

    if (ApolloURLLooksLikeAnimatedGIF(normalizedURL)) {
        objc_setAssociatedObject(imageNode, &kApolloInlineAnimatedGIFKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Long-press: install a UIContextMenuInteraction once the imageNode's
    // backing view exists. Native iOS routes context menus to the deepest
    // interaction-bearing view, so this wins over Apollo's cell-level
    // upvote/save/reply menu when the touch is inside the image bounds.
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        if ([objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) return;
        UIView *v = [img view];
        if (!v) return;
        ApolloMirrorImageURLsToLoadedView(img);
        if ([objc_getAssociatedObject(img, &kApolloInlineAnimatedGIFKey) boolValue]) {
            ApolloMarkViewAsInlineGIF(v);
            UIImage *storedCover = objc_getAssociatedObject(img, &kApolloInlineGIFCoverImageKey);
            ApolloApplyInlineGIFPlaybackPolicyWithCover(img, storedCover, 0);
        }
        UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
            initWithDelegate:[ApolloInlineImageDispatcher shared]];
        [v addInteraction:menu];
        objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];

    return imageNode;
}

// MARK: - Layout-spec wrapping (ratio + inset)

// Bounds for the container's aspect ratio (height / width). Images outside
// these bounds get a clamped container with the image aspect-fit inside —
// preserves natural proportions and avoids degenerate sizes (extremely
// tall cells spanning multiple screens; near-zero-height slivers).
static const CGFloat kApolloMaxContainerRatio = 1.0;   // tallest: square (height ≤ width)
static const CGFloat kApolloMinContainerRatio = 0.18; // shortest: ~5.5:1 landscape

// Floor for the container width when shrinking tall images to image-tight
// width. ~2 thumb widths — keeps super-narrow images from collapsing into
// a sliver. Below this, the image letterboxes inside a min-width container.
static const CGFloat kApolloMinTallImageWidth = 85.0;

// Secondary height cap as a fraction of the current screen height. Keeps
// inline images from filling the entire viewport in landscape, where the
// row is wide but vertical space is scarce. In portrait this rarely
// binds (screen × 0.6 > row × 1.0 on phones and tablets), so portrait
// sizing stays unchanged.
static const CGFloat kApolloMaxScreenHeightFraction = 0.6;

// MARK: - Inline media layout registry (live size/alignment changes)
//
// Every inline media leaf that measures through ApolloWrapImageNodeForLayout
// is tracked weakly so the Inline Media settings screen can re-measure the
// visible comments the moment Size or Alignment changes — no leaving the
// thread and coming back.
static NSHashTable *sApolloInlineMediaLayoutNodes = nil;

static void ApolloRegisterInlineMediaLayoutNode(ASDisplayNode *node) {
    if (!node) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloInlineMediaLayoutNodes = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (sApolloInlineMediaLayoutNodes) {
        [sApolloInlineMediaLayoutNodes addObject:node];
    }
}

static void ApolloRefreshInlineMediaLayout(void) {
    if (!sApolloInlineMediaLayoutNodes) return;
    NSArray *nodes = nil;
    @synchronized (sApolloInlineMediaLayoutNodes) {
        nodes = sApolloInlineMediaLayoutNodes.allObjects;
    }
    SEL relayoutSel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    NSUInteger relaid = 0;
    for (ASDisplayNode *node in nodes) {
        if (![node respondsToSelector:relayoutSel]) continue;
        @try {
            if (!node.supernode) continue;
            ((void (*)(id, SEL))objc_msgSend)(node, relayoutSel);
            relaid++;
        } @catch (__unused NSException *exception) {}
    }
    ApolloLog(@"[InlineImages] media layout refresh nodes=%lu relaid=%lu",
              (unsigned long)nodes.count, (unsigned long)relaid);
}

static ASLayoutSpec *ApolloWrapImageNodeForLayout(ASNetworkImageNode *imageNode,
                                                   CGFloat rowMaxWidth) {
    ApolloRegisterInlineMediaLayoutNode((ASDisplayNode *)imageNode);
    NSNumber *ratioNum = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (!ratioNum) {
        // Unknown ratio → omit from layout. Including with a guessed ratio
        // would cause cell measurement to capture the wrong size and race
        // with the post-load relayout-from-above.
        return nil;
    }
    CGFloat naturalRatio = [ratioNum doubleValue];
    if (naturalRatio <= 0) naturalRatio = 1.0;

    CGFloat containerRatio = naturalRatio;
    CGFloat containerWidth = rowMaxWidth;  // default: span full row
    BOOL isLetterboxed = NO;

    if (naturalRatio > kApolloMaxContainerRatio) {
        // Tall image. Cap height at min(row × maxContainerRatio,
        // screen × maxScreenHeightFraction). The screen term protects
        // landscape, where the row term alone produces images taller
        // than the viewport. Within that cap, shrink container width
        // to image-tight (no letterbox) unless that would make the
        // container too narrow, in which case pin to a min width and
        // letterbox inside (still height-capped).
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        CGFloat maxContainerHeight = MIN(rowMaxWidth * kApolloMaxContainerRatio,
                                          screenHeight * kApolloMaxScreenHeightFraction);
        CGFloat tightWidth = maxContainerHeight / naturalRatio;
        if (tightWidth >= kApolloMinTallImageWidth) {
            containerWidth = tightWidth;
            containerRatio = naturalRatio;
        } else {
            containerWidth = kApolloMinTallImageWidth;
            // Container ratio derived so height equals maxContainerHeight.
            containerRatio = maxContainerHeight / kApolloMinTallImageWidth;
            isLetterboxed = YES;
        }
    } else if (naturalRatio < kApolloMinContainerRatio) {
        // Wide image: keep full row width, letterbox inside a clamped
        // min-ratio container.
        containerWidth = rowMaxWidth;
        containerRatio = kApolloMinContainerRatio;
        isLetterboxed = YES;
    } else {
        // Normal aspect. Tight-wrap, but enforce the screen height cap
        // so a landscape-wide normal image (e.g. 16:9 at full row width)
        // doesn't dominate the viewport.
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        CGFloat heightCap = screenHeight * kApolloMaxScreenHeightFraction;
        CGFloat naturalHeight = rowMaxWidth * naturalRatio;
        if (naturalHeight > heightCap) {
            containerWidth = heightCap / naturalRatio;
            containerRatio = naturalRatio;
        }
    }

    // Border only when letterboxed (natural ratio doesn't match container
    // ratio). Tightly-wrapped tall images have the image at the container
    // edge — a border there would overlap image content.
    if (isLetterboxed) {
        imageNode.borderWidth = 0.75;
        imageNode.borderColor = [UIColor separatorColor].CGColor;
    } else {
        imageNode.borderWidth = 0.0;
    }

    ASRatioLayoutSpec *ratioSpec = [ApolloASRatioLayoutSpecClass() ratioLayoutSpecWithRatio:containerRatio child:imageNode];
    [[ratioSpec style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    // User-selected inline media size (100/75/50% of the row width). Applied
    // as a width cap so the ratio spec keeps height proportional; the slack
    // distribution below then positions the smaller container per alignment.
    if (sInlineMediaSizePercent > 0 && sInlineMediaSizePercent < 100) {
        containerWidth = MIN(containerWidth, rowMaxWidth * (sInlineMediaSizePercent / 100.0));
    }

    // Position the container horizontally per user preference.
    // Only has a visual effect when containerWidth < rowMaxWidth (tall portrait
    // images, height-capped images). Wide / full-row images are unaffected.
    CGFloat slack = MAX(0.0, rowMaxWidth - containerWidth);
    CGFloat leftInset, rightInset;
    if (sInlineImageAlignment == ApolloInlineImageAlignmentLeft) {
        leftInset = 0;
        rightInset = slack;
    } else if (sInlineImageAlignment == ApolloInlineImageAlignmentRight) {
        leftInset = slack;
        rightInset = 0;
    } else {
        leftInset = slack * 0.5;
        rightInset = slack * 0.5;
    }
    UIEdgeInsets insets = UIEdgeInsetsMake(4, leftInset, 4, rightInset);
    ASInsetLayoutSpec *insetSpec = [ApolloASInsetLayoutSpecClass() insetLayoutSpecWithInsets:insets child:ratioSpec];
    [[insetSpec style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];
    return insetSpec;
}

// MARK: - Text-splitting

// Trim leading/trailing newlines + spaces from an attributed substring so we
// don't have stranded blank lines after removing the URL text.
static NSAttributedString *ApolloTrimAttributedString(NSAttributedString *s) {
    if (s.length == 0) return s;
    NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *str = s.string;
    NSUInteger start = 0;
    while (start < str.length && [trim characterIsMember:[str characterAtIndex:start]]) start++;
    NSUInteger end = str.length;
    while (end > start && [trim characterIsMember:[str characterAtIndex:end - 1]]) end--;
    if (start == 0 && end == str.length) return s;
    if (end <= start) return [[NSAttributedString alloc] initWithString:@""];
    return [s attributedSubstringFromRange:NSMakeRange(start, end - start)];
}

static ASTextNode *ApolloMakeTextSegmentNode(ASTextNode *templateTextNode, NSAttributedString *segment) {
    // Use the template's class (e.g. _TtC6Apollo16MarkdownTextNode) and
    // mirror Apollo's markdown-parser property setup (per RE of
    // sub_1004280f8). userInteractionEnabled=YES is required — without it,
    // taps fall straight through to the cell.
    ASTextNode *tn = [[[templateTextNode class] alloc] init];
    tn.longPressCancelsTouches = YES;
    tn.userInteractionEnabled = YES;
    tn.delegate = templateTextNode.delegate;
    tn.passthroughNonlinkTouches = templateTextNode.passthroughNonlinkTouches;

    // Apollo's link key isn't NSLinkAttributeName — copy from the template.
    NSArray *names = templateTextNode.linkAttributeNames;
    if (names.count > 0) tn.linkAttributeNames = names;

    tn.maximumNumberOfLines = templateTextNode.maximumNumberOfLines;
    tn.attributedText = segment;
    [[tn style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];
    return tn;
}

static void ApolloRequestMarkdownRelayout(ASDisplayNode *hostMarkdownNode) {
    if (!hostMarkdownNode) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASDisplayNode *n = hostMarkdownNode;
        while (n) {
            if ([n respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                [n invalidateCalculatedLayout];
            }
            if ([n respondsToSelector:@selector(setNeedsLayout)]) {
                [n setNeedsLayout];
            }
            n = n.supernode;
        }
        SEL relayoutSel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        if ([hostMarkdownNode respondsToSelector:relayoutSel]) {
            ((void (*)(id, SEL))objc_msgSend)(hostMarkdownNode, relayoutSel);
        }
    });
}

// Reddit GIFs posted in comments arrive as /link/<post>/video/<asset>/player
// URLs. They're only recognized as inline-autoplaying GIFs once the hosting
// comment's mediaMetadata is reachable (ApolloInlineGIFDisplayURLFromMetadata
// rewrites the /player URL to i.redd.it/<asset>.gif). But the very first
// layoutSpecThatFits: pass can run before the MarkdownNode is connected to its
// CommentCellNode, so ApolloMediaMetadataForHost returns nil and the URL is
// (mis)classified as a plain video thumbnail — a static poster + play button
// that never animates. Collapsing and re-expanding the comment recreates the
// text nodes, which rebuilds the decomposition once metadata IS reachable,
// which is why that manual workaround "fixes" it.
//
// This poll closes that gap automatically: when leaves were built without
// metadata and at least one candidate could be a Reddit-hosted GIF, retry
// reading the metadata for a short window. The moment it resolves to a GIF,
// invalidate the cached children (kApolloCachedOrigChildrenKey) — exactly what
// collapse/expand does implicitly — and request a relayout so the next pass
// reclassifies the /player URL as an inline GIF and autoplays it.
static void ApolloScheduleInlineGIFMetadataRetry(ASDisplayNode *hostMarkdownNode,
                                                  NSArray<NSURL *> *candidateVideoURLs,
                                                  NSUInteger attempt) {
    if (!hostMarkdownNode || candidateVideoURLs.count == 0) return;
    static const NSTimeInterval kDelays[] = {0.10, 0.20, 0.35, 0.60, 1.0, 2.0};
    static const NSUInteger kMaxAttempts = sizeof(kDelays) / sizeof(kDelays[0]);
    if (attempt >= kMaxAttempts) return;

    __weak ASDisplayNode *weakHost = hostMarkdownNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ASDisplayNode *host = weakHost;
        if (!host) return;

        NSDictionary *md = ApolloMediaMetadataForHost(host);
        if (md.count > 0) {
            BOOL foundGIF = NO;
            for (NSURL *u in candidateVideoURLs) {
                if (ApolloInlineGIFDisplayURLFromMetadata(u, md)) { foundGIF = YES; break; }
            }
            if (foundGIF) {
                // Force the decomposition rebuild (same effect as collapse/expand)
                // so the /player URL is reclassified as a GIF on the next layout.
                objc_setAssociatedObject(host, &kApolloCachedOrigChildrenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloRequestMarkdownRelayout(host);
                ApolloLog(@"[InlineImages] reddit GIF metadata arrived — rebuilding decomposition host=%p attempt=%lu",
                          host, (unsigned long)attempt);
                return;
            }
            // Metadata is present but none of the candidates are GIFs — they're
            // genuine videos. Leave them as thumbnails and stop polling.
            return;
        }
        // Metadata still unreachable — keep trying within the window.
        ApolloScheduleInlineGIFMetadataRetry(host, candidateVideoURLs, attempt + 1);
    });
}

static NSUInteger ApolloUniqueImageChestPostLinkCount(NSAttributedString *attr);

// Returns an array of leaf nodes (ASTextNode + ASNetworkImageNode instances)
// in the order they should appear in the augmented stack, replacing the
// original text node. Returns nil if the text node has no inline media URLs.
// Side effects: each new leaf is added as a subnode of `hostMarkdownNode`.
static NSArray *ApolloBuildLeavesForTextNode(ASTextNode *textNode,
                                              ASDisplayNode *hostMarkdownNode) {
    NSAttributedString *attr = textNode.attributedText;
    if (attr.length == 0) return nil;

    // Collect (range, url, kind) tuples for inline media URLs, deduping by URL string.
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    // Pre-normalize URLs, used for the bare-URL text check — the
    // displayed text matches the original form, not the normalized one.
    NSMutableArray<NSURL *> *originalURLs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *isVideoURL = [NSMutableArray array];
    NSMutableArray<NSNumber *> *isImageChestURL = [NSMutableArray array];
    NSMutableArray<NSNumber *> *isBareURL = [NSMutableArray array];
    // Issue #392: the link/alt text is just the default word "gif" — drop the
    // redundant label beneath the inline GIF (custom alt text stays visible).
    NSMutableArray<NSNumber *> *isDefaultGifLabel = [NSMutableArray array];
    NSMutableSet<NSString *> *seenAbs = [NSMutableSet set];
    NSUInteger imageChestPostLinkCount = ApolloUniqueImageChestPostLinkCount(attr);
    NSDictionary *hostMediaMetadata = ApolloMediaMetadataForHost(hostMarkdownNode);
    // Original /player URLs classified as video while metadata was unavailable;
    // used to schedule a metadata-arrival retry (see below).
    NSMutableArray<NSURL *> *videoCandidates = [NSMutableArray array];

    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        for (NSAttributedStringKey k in attrs) {
            id val = attrs[k];
            if (![val isKindOfClass:[NSURL class]]) continue;
            NSURL *url = (NSURL *)val;
            if (ApolloImageChestIsPostURL(url) && imageChestPostLinkCount != 1) {
                continue;
            }
            if (ApolloImageChestIsPostURL(url) && !ApolloImageChestCachedResolution(url)) {
                // Avoid deleting the text/link until the public page has
                // resolved; failed/private/deleted albums keep Apollo's normal
                // link behavior rather than becoming a blank inline slot.
                if (!ApolloImageChestCachedFailureExists(url)) {
                    ApolloImageChestResolveURL(url, ^(NSDictionary *result) {
                        if (result) ApolloRequestMarkdownRelayout(hostMarkdownNode);
                    });
                }
                continue;
            }
            NSURL *urlForClassify = url;
            NSURL *metadataGIF = ApolloInlineGIFDisplayURLFromMetadata(url, hostMediaMetadata);
            if (metadataGIF) urlForClassify = metadataGIF;
            BOOL isImage = ApolloIsInlineRenderableImageURL(urlForClassify);
            BOOL isVideo = !isImage && ApolloIsInlineRenderableVideoURL(urlForClassify);
            if (!isImage && !isVideo) continue;
            if (isVideo && !metadataGIF) [videoCandidates addObject:url];
            // Expand to the URL's longest effective range so a markdown
            // link with mixed formatting ("[**Bold** plain](url)") gets
            // captured as one span instead of two.
            NSRange fullRange = range;
            (void)[attr attribute:k atIndex:range.location longestEffectiveRange:&fullRange
                          inRange:NSMakeRange(0, attr.length)];
            NSURL *normalized = ApolloNormalizeInlineImageURL(metadataGIF ?: url);
            NSString *abs = normalized.absoluteString;
            if (!abs.length || [seenAbs containsObject:abs]) continue;
            BOOL imageChestURL = ApolloImageChestIsPostURL(url);
            BOOL bareURL = ApolloRangeTextLooksLikeBareURL(attr, fullRange, url);
            BOOL defaultGifLabel = ApolloRangeTextIsDefaultGIFLabel(attr, fullRange);
            [seenAbs addObject:abs];
            ApolloRegisterInlineSuppressionURL(url);
            ApolloRegisterInlineSuppressionURL(normalized);
            [ranges addObject:[NSValue valueWithRange:fullRange]];
            [urls addObject:normalized];
            [originalURLs addObject:url];
            [isVideoURL addObject:@(isVideo)];
            [isImageChestURL addObject:@(imageChestURL)];
            [isBareURL addObject:@(bareURL)];
            [isDefaultGifLabel addObject:@(defaultGifLabel)];
        }
    }];

    // If we classified one or more URLs as video thumbnails but couldn't reach
    // the comment's mediaMetadata yet, the /player URL might actually be a
    // Reddit-hosted GIF. Poll for the metadata and rebuild once it arrives so
    // the GIF autoplays inline without the user collapsing/expanding the cell.
    // We ALSO mark this decomposition provisional so layoutSpecThatFits: does
    // not cache it: an off-screen comment lays out during preheat (metadata
    // unreachable) and the timed poll can give up before the cell ever becomes
    // visible. Leaving the result uncached forces a fresh rebuild on the
    // display-time measurement pass — when the metadata IS reachable — so the
    // GIF is reclassified correctly the moment the user scrolls to it.
    if (hostMediaMetadata == nil && videoCandidates.count > 0) {
        objc_setAssociatedObject(hostMarkdownNode, &kApolloProvisionalDecompKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloScheduleInlineGIFMetadataRetry(hostMarkdownNode, videoCandidates, 0);
    }

    if (ranges.count == 0) return nil;

    // Sort by range.location ascending.
    NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:ranges.count];
    for (NSUInteger i = 0; i < ranges.count; i++) [idx addObject:@(i)];
    [idx sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger la = [ranges[a.unsignedIntegerValue] rangeValue].location;
        NSUInteger lb = [ranges[b.unsignedIntegerValue] rangeValue].location;
        return (la < lb) ? NSOrderedAscending : (la > lb) ? NSOrderedDescending : NSOrderedSame;
    }];

    NSMutableArray *leaves = [NSMutableArray array];

    // Process per-paragraph (\n-delimited spans). Within each paragraph,
    // images stack at the top and the remaining text follows. Across
    // paragraphs, source order is preserved — so "Plain text\nhttps://gif"
    // renders as text then image, while "[a](url1) and [b](url2)" (single
    // line) renders as image1, image2, then "a and b".
    NSString *str = attr.string;

    void (^processParagraph)(NSUInteger, NSUInteger) = ^(NSUInteger pStart, NSUInteger pEnd) {
        if (pEnd <= pStart) return;
        NSRange pRange = NSMakeRange(pStart, pEnd - pStart);

        // Indices (into ranges/urls) for URLs falling inside this paragraph.
        NSMutableArray<NSNumber *> *pIdx = [NSMutableArray array];
        for (NSNumber *iNum in idx) {
            NSRange r = [ranges[iNum.unsignedIntegerValue] rangeValue];
            if (r.location >= pStart && NSMaxRange(r) <= pEnd) [pIdx addObject:iNum];
        }

        NSMutableArray *prefixImageNodes = [NSMutableArray array];
        NSMutableArray *appendImageNodes = [NSMutableArray array];
        for (NSNumber *iNum in pIdx) {
            NSUInteger leafIndex = iNum.unsignedIntegerValue;
            ASNetworkImageNode *img = [isVideoURL[leafIndex] boolValue]
                ? ApolloVideoThumbnailNodeForURL(urls[leafIndex], hostMarkdownNode)
                : ApolloImageNodeForURL(urls[leafIndex], hostMarkdownNode);
            if (img) {
                // Route tap/long-press to the original posted URL when
                // it differs from the loaded URL — Copy Link returns
                // what the user shared, and album taps route to the
                // album viewer instead of just the cover image.
                NSURL *original = originalURLs[leafIndex];
                if (original && ![original.absoluteString isEqualToString:urls[leafIndex].absoluteString]) {
                    ApolloSetOriginalImageURL(img, original);
                }
                BOOL appendAfterText = [isImageChestURL[leafIndex] boolValue] && ![isBareURL[leafIndex] boolValue];
                [(appendAfterText ? appendImageNodes : prefixImageNodes) addObject:img];
            }
        }

        [leaves addObjectsFromArray:prefixImageNodes];

        NSMutableAttributedString *remaining = [[attr attributedSubstringFromRange:pRange] mutableCopy];
        // Reverse-order deletion of redundant label ranges (paragraph-relative):
        // bare URLs (the text just repeats the link) and default "GIF" labels
        // (issue #392 — the GIF is shown inline, so its "GIF" caption is noise).
        for (NSInteger n = (NSInteger)pIdx.count - 1; n >= 0; n--) {
            NSUInteger ri = [pIdx[n] unsignedIntegerValue];
            NSRange r = [ranges[ri] rangeValue];
            if (![isBareURL[ri] boolValue] && ![isDefaultGifLabel[ri] boolValue]) continue;
            NSUInteger loc = r.location - pStart;
            NSUInteger len = r.length;
            // If the removed label sits between two spaces (mid-sentence, e.g.
            // "lol [gif](url) so funny"), also consume one flanking space so we
            // don't leave a doubled interior space. ApolloTrimAttributedString
            // only trims the string's leading/trailing whitespace, not interior
            // runs. Checked against the current `remaining` state, which is safe
            // because we delete highest-location ranges first, leaving the chars
            // at and before `loc` untouched for lower-location ranges.
            NSString *s = remaining.string;
            if (loc >= 1 && loc + len < s.length) {
                NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
                if ([ws characterIsMember:[s characterAtIndex:loc - 1]] &&
                    [ws characterIsMember:[s characterAtIndex:loc + len]]) {
                    len += 1; // drop the trailing space of the pair
                }
            }
            [remaining deleteCharactersInRange:NSMakeRange(loc, len)];
        }

        NSAttributedString *trimmed = ApolloTrimAttributedString(remaining);
        if (trimmed.length > 0) {
            ASTextNode *tn = ApolloMakeTextSegmentNode(textNode, trimmed);
            if (tn) {
                [leaves addObject:tn];
                [hostMarkdownNode addSubnode:tn];
            }
        }

        [leaves addObjectsFromArray:appendImageNodes];
    };

    NSUInteger pStart = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        if ([str characterAtIndex:i] == '\n') {
            processParagraph(pStart, i);
            pStart = i + 1;
        }
    }
    processParagraph(pStart, str.length);

    return leaves.count > 0 ? [leaves copy] : nil;
}

// Reuses an existing imageNode by URL if present, else creates and
// registers one. Avoids recreate-then-remove churn during rapid Apollo
// MarkdownNode rebuilds (cell collapse/uncollapse).
static ASNetworkImageNode *ApolloImageNodeForURL(NSURL *normalizedURL,
                                                   ASDisplayNode *hostMarkdownNode) {
    NSMutableDictionary *cache = objc_getAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = [normalizedURL absoluteString];
    ASNetworkImageNode *existing = key ? cache[key] : nil;
    if (existing) {
        // Reuse: ensure the host association is still up to date in case
        // (somehow) it pointed elsewhere previously.
        objc_setAssociatedObject(existing, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
        // If this is a cached album/gallery node whose resolution never
        // completed (e.g. previous host was deallocated mid-fetch), kick
        // off another resolve attempt — the resolver dedupes on cacheKey.
        if (ApolloIsImgurAlbumOrGalleryURL(normalizedURL) && !objc_getAssociatedObject(existing, &kApolloImageURLKey)) {
            __weak ASNetworkImageNode *weakImage = existing;
            ApolloResolveImgurURL(normalizedURL, ^(NSDictionary *result) {
                ASNetworkImageNode *strong = weakImage;
                if (!strong || !result) return;
                ApolloApplyResolvedAlbumImage(strong, result);
            });
        } else if (ApolloImageChestIsPostURL(normalizedURL) && !objc_getAssociatedObject(existing, &kApolloImageURLKey)) {
            __weak ASNetworkImageNode *weakImage = existing;
            ApolloImageChestResolveURL(normalizedURL, ^(NSDictionary *result) {
                ASNetworkImageNode *strong = weakImage;
                if (!strong || !result) return;
                ApolloApplyResolvedAlbumImage(strong, result);
            });
        }
        return existing;
    }

    ASNetworkImageNode *imageNode = ApolloMakeInlineImageNode(normalizedURL, hostMarkdownNode);
    if (!imageNode) return nil;
    [hostMarkdownNode addSubnode:imageNode];
    if (key) cache[key] = imageNode;
    return imageNode;
}

static ASNetworkImageNode *ApolloVideoThumbnailNodeForURL(NSURL *normalizedURL,
                                                           ASDisplayNode *hostMarkdownNode) {
    NSMutableDictionary *cache = objc_getAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = [normalizedURL absoluteString];
    ASNetworkImageNode *existing = key ? cache[key] : nil;
    if (existing) {
        objc_setAssociatedObject(existing, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
        return existing;
    }

    ASNetworkImageNode *videoNode = ApolloMakeInlineVideoThumbnailNode(normalizedURL, hostMarkdownNode);
    if (!videoNode) return nil;
    [hostMarkdownNode addSubnode:videoNode];
    if (key) cache[key] = videoNode;
    return videoNode;
}
// Compare two children arrays by element-pointer identity. Apollo bridges
// its Swift `[ASDisplayNode]` to a fresh NSArray each layoutSpecThatFits:
// call, so the wrapping pointer differs every time but the element pointers
// are reused — that's the right cache invariant.
static BOOL ApolloChildrenIdentityMatches(NSArray *a, NSArray *b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (a[i] != b[i]) return NO;
    }
    return YES;
}

static id ApolloModelFromNodeIvar(ASDisplayNode *node, const char *ivarName) {
    if (!node || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([node class], ivarName);
    if (!ivar) return nil;
    id model = nil;
    @try {
        model = object_getIvar(node, ivar);
    } @catch (NSException *e) {
        ApolloLog(@"[InlineImages] ivar read failed node=%@ ivar=%s err=%@",
                  NSStringFromClass([node class]), ivarName, e.reason ?: e.name);
    }
    return model;
}

static BOOL ApolloModelRepresentsInlineHost(id model, BOOL isComment) {
    if (!model) return NO;
    if (isComment) return YES;
    if ([model respondsToSelector:@selector(isSelfPostWithSelfText)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(isSelfPostWithSelfText))) {
        return YES;
    }
    return NO;
}

static NSUInteger ApolloUniqueImageChestPostLinkCount(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return 0;

    NSMutableSet<NSString *> *postIDs = [NSMutableSet set];
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, __unused BOOL *stop) {
        for (NSAttributedStringKey key in attrs) {
            id value = attrs[key];
            if (![value isKindOfClass:[NSURL class]]) continue;
            NSString *postID = ApolloImageChestPostIDFromURL((NSURL *)value);
            if (postID.length > 0) [postIDs addObject:postID];
        }
    }];
    return postIDs.count;
}

static BOOL ApolloLinkButtonHasInlineHost(ASDisplayNode *linkButtonNode) {
    for (ASDisplayNode *n = linkButtonNode; n; n = n.supernode) {
        id comment = ApolloModelFromNodeIvar(n, "comment");
        if (ApolloModelRepresentsInlineHost(comment, YES)) {
            return YES;
        }

        id link = ApolloModelFromNodeIvar(n, "link");
        if (ApolloModelRepresentsInlineHost(link, NO)) {
            return YES;
        }
    }
    return NO;
}

// MARK: - %hook _TtC6Apollo12MarkdownNode

%hook _TtC6Apollo12MarkdownNode

- (void)textNode:(id)textNode tappedLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point textRange:(NSRange)range {
    NSURL *url = [value isKindOfClass:[NSURL class]] ? (NSURL *)value : ([value isKindOfClass:[NSString class]] ? [NSURL URLWithString:(NSString *)value] : nil);
    if (ApolloImageChestIsPostURL(url)) {
        UIView *sourceView = [(id)self respondsToSelector:@selector(view)] ? ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(view)) : nil;
        if (ApolloPresentOrResolveImageChestAlbumURL(url, sourceView, ^{
            ApolloOpenImageChestURLNormally(url);
        })) {
            ApolloLog(@"[ImageChest] intercepted markdown tap %@", url);
            return;
        }
    }

    %orig(textNode, attribute, value, point, range);
}

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    id origSpec = %orig;
    if (!sEnableInlineImages) return origSpec;
    if (![origSpec isKindOfClass:ApolloASStackLayoutSpecClass()]) return origSpec;

    ASStackLayoutSpec *stack = (ASStackLayoutSpec *)origSpec;
    NSArray *origChildren = stack.children;
    if (origChildren.count == 0) return origSpec;

    NSArray *cachedOrigChildren = objc_getAssociatedObject(self, &kApolloCachedOrigChildrenKey);
    NSDictionary *decomp = objc_getAssociatedObject(self, &kApolloDecompositionMapKey);

    if (!ApolloChildrenIdentityMatches(cachedOrigChildren, origChildren)) {
        // Rebuild decomposition. We do NOT removeFromSupernode the previous
        // imageNodes here — ApolloImageNodeForURL reuses them by URL. Text
        // segments ARE recreated each time (cheap, attributedText varies).
        // ApolloBuildLeavesForTextNode sets kApolloProvisionalDecompKey if it
        // had to classify a Reddit /player GIF without reachable metadata;
        // clear it first so it reflects only this rebuild.
        objc_setAssociatedObject(self, &kApolloProvisionalDecompKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableDictionary *newDecomp = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *referencedURLs = [NSMutableSet set];
        Class textNodeCls = ApolloASTextNodeClass();
        Class imageNodeCls = ApolloASNetworkImageNodeClass();
        for (id child in origChildren) {
            if (![child isKindOfClass:textNodeCls]) continue;
            NSArray *leaves = ApolloBuildLeavesForTextNode((ASTextNode *)child, (ASDisplayNode *)self);
            if (leaves.count > 0) {
                NSValue *k = [NSValue valueWithNonretainedObject:child];
                newDecomp[k] = leaves;
                for (id leaf in leaves) {
                    if ([leaf isKindOfClass:imageNodeCls]) {
                        // Use kApolloImageCacheKey (matches cache key) —
                        // imageNode.URL changes after Imgur album resolution
                        // and kApolloImageURLKey can be the original share
                        // URL for tap routing; either would mis-GC here.
                        NSString *abs = objc_getAssociatedObject(leaf, &kApolloImageCacheKey)
                                     ?: [((ASNetworkImageNode *)leaf).URL absoluteString];
                        if (abs) [referencedURLs addObject:abs];
                    }
                }
            }
        }

        // Garbage-collect imageNodes whose URL no longer appears in the new
        // decomposition (e.g., the comment was edited and the URL removed).
        NSMutableDictionary *imageCache = objc_getAssociatedObject(self, &kApolloImageNodesByURLKey);
        if (imageCache.count > 0) {
            NSArray *cachedURLs = [imageCache.allKeys copy];
            for (NSString *cachedURL in cachedURLs) {
                if (![referencedURLs containsObject:cachedURL]) {
                    ASNetworkImageNode *staleNode = imageCache[cachedURL];
                    if ([staleNode isKindOfClass:[ApolloASNetworkImageNodeClass() class]]) {
                        ApolloClearInlineGIFNodeState(staleNode);
                    }
                    [staleNode removeFromSupernode];
                    [imageCache removeObjectForKey:cachedURL];
                }
            }
        }

        // Always save the orig children (even when no decomposition needed) so
        // we can short-circuit subsequent calls that match this content.
        // EXCEPTION: if the decomposition is provisional (a Reddit /player GIF
        // was classified as a video thumbnail because the comment's
        // mediaMetadata wasn't reachable yet), do NOT cache the orig children.
        // Leaving the cache empty forces a full rebuild on the next
        // layoutSpecThatFits: pass — which, for an off-screen comment, is the
        // display-time measurement when metadata becomes reachable — so the GIF
        // is reclassified and autoplays instead of staying a static thumbnail.
        BOOL provisional = [objc_getAssociatedObject(self, &kApolloProvisionalDecompKey) boolValue];
        objc_setAssociatedObject(self, &kApolloCachedOrigChildrenKey, provisional ? nil : origChildren, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kApolloDecompositionMapKey, newDecomp.count > 0 ? newDecomp : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        decomp = newDecomp.count > 0 ? newDecomp : nil;
    }

    if (decomp.count == 0) return origSpec;

    // Replace each decomposed text node with its leaves. Image nodes whose
    // ratio is still unknown are omitted — DIDLOAD will trigger a layout-
    // from-above and they'll appear on the next pass.
    NSMutableArray *augmented = [NSMutableArray arrayWithCapacity:origChildren.count];
    Class imageNodeCls = ApolloASNetworkImageNodeClass();
    CGFloat rowMaxWidth = constrainedSize.max.width;
    for (id child in origChildren) {
        NSArray *leaves = decomp[[NSValue valueWithNonretainedObject:child]];
        if (!leaves) {
            [augmented addObject:child];
            continue;
        }
        for (id leaf in leaves) {
            if ([leaf isKindOfClass:imageNodeCls]) {
                ASLayoutSpec *wrapped = ApolloWrapImageNodeForLayout((ASNetworkImageNode *)leaf, rowMaxWidth);
                if (wrapped) [augmented addObject:wrapped];
            } else {
                [augmented addObject:leaf];
            }
        }
    }

    ASStackLayoutSpec *newSpec = [ApolloASStackLayoutSpecClass() stackLayoutSpecWithDirection:stack.direction
                                                                                      spacing:stack.spacing
                                                                               // Override Apollo's spaceBetween — it spreads our
                                                                               // multi-child augmented layout when slack is available.
                                                                               justifyContent:ApolloASStackLayoutJustifyContentStart
                                                                                   alignItems:stack.alignItems
                                                                                     children:augmented];
    newSpec.flexWrap = stack.flexWrap;
    newSpec.alignContent = stack.alignContent;
    newSpec.lineSpacing = stack.lineSpacing;
    return newSpec;
}

%end

// MARK: - %hook _TtC6Apollo14LinkButtonNode

// Hides Apollo's link-card preview when the URL has been inlined as an
// image elsewhere in the same cell. Returns a zero-size empty spec so
// the LinkButtonNode reserves no visible space. For link posts (no
// selftext / no MarkdownNode body), there is no inline replacement, so
// the preview is preserved.

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if (!sEnableInlineImages) return %orig;

    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    if (!urlString) return %orig;

    NSURL *url = [NSURL URLWithString:urlString];

    // #552: an ImgChest album LINK POST (imgchest.com/p/<id>) has no MarkdownNode
    // body to carry an inline replacement, so previously nothing rendered the
    // album here and the LinkPreviews card was suppressed → blank. Render the
    // album cover inline (tap → the same swipeable viewer as in-text links),
    // reusing the resolver + per-host node cache. If the same album was already
    // inlined in a text body, hide this card to avoid a duplicate cover.
    if (ApolloImageChestIsPostURL(url)) {
        BOOL alreadyInlined = ApolloLinkButtonHasInlineHost((ASDisplayNode *)self)
                           || ApolloInlineSuppressionContainsURL(url);
        if (alreadyInlined) {
            Class layoutSpecCls = NSClassFromString(@"ASLayoutSpec");
            if (layoutSpecCls) {
                ASLayoutSpec *empty = [[layoutSpecCls alloc] init];
                [[empty style] setValue:[NSValue valueWithCGSize:CGSizeZero] forKey:@"preferredSize"];
                return empty;
            }
            return %orig;
        }
        ASNetworkImageNode *coverNode = ApolloImageNodeForURL(url, (ASDisplayNode *)self);
        ASLayoutSpec *wrapped = coverNode ? ApolloWrapImageNodeForLayout(coverNode, constrainedSize.max.width) : nil;
        if (wrapped) return wrapped;   // resolved → album cover shown inline
        return %orig;                  // still resolving → native card as placeholder
    }

    if (!ApolloIsInlineRenderableImageURL(url) && !ApolloIsInlineRenderableVideoURL(url)) return %orig;

    // Album inline rendering depends on async resolution. Until that succeeds,
    // keep Apollo's native LinkButtonNode preview so private/deleted/bad albums
    // don't turn into a blank gap.
    if (ApolloIsImgurAlbumOrGalleryURL(url) && !ApolloCachedImgurResolution(url)) return %orig;
    if (ApolloImageChestIsPostURL(url) && !ApolloImageChestCachedResolution(url)) return %orig;

    // Only hide if there's a MarkdownNode body that would carry the
    // inline replacement. LinkButtonNode is sometimes measured while
    // detached (supernode == nil), so fall back to URLs registered by the
    // MarkdownNode inline pass.
    BOOL haveInlineReplacement = ApolloLinkButtonHasInlineHost((ASDisplayNode *)self)
                              || ApolloInlineSuppressionContainsURL(url);
    if (!haveInlineReplacement) return %orig;

    Class layoutSpecCls = NSClassFromString(@"ASLayoutSpec");
    if (!layoutSpecCls) return %orig;

    ASLayoutSpec *empty = [[layoutSpecCls alloc] init];
    [[empty style] setValue:[NSValue valueWithCGSize:CGSizeZero] forKey:@"preferredSize"];
    return empty;
}

%end

%ctor {
    ApolloMediaAutoplayInstall();
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloInlineMediaLayoutDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloRefreshInlineMediaLayout();
    }];
}
