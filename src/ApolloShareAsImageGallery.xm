// ApolloShareAsImageGallery.xm
//
// "Share as Image" gallery support.
//
// Apollo's SaveAsImagePreviewNode (_TtC6Apollo22SaveAsImagePreviewNode) renders
// a post into a shareable image. It has a single `imageNode` (fed by the
// `imageForImagePost` ivar) plus a fallback `linkButtonNode`. For a multi-image
// GALLERY post, Apollo passes imageForImagePost = nil, so the preview falls
// back to the compact link card ("Gallery <id>") instead of showing the images.
//
// This module detects gallery posts in the preview node, fetches the gallery
// item images, composes a feed-style collage UIImage, and injects it through
// Apollo's own single-image path (imageForImagePost + imageNode) while nil-ing
// the linkButtonNode so the compact card is dropped. We re-use Apollo's native
// layout/snapshot pipeline rather than building our own layout, so the exported
// image and the live preview both pick up the collage on the next layout pass.
//
// No hardcoded binary addresses: everything is done through ObjC runtime ivar
// access (ivar names from class-dump headers) and defensive selector checks.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloHostedVideo.h"

// ASSizeRange is { CGSize min; CGSize max; }. The rest of the repo matches the
// -layoutSpecThatFits: selector ABI with `struct CDStruct_90e057aa` from the
// class-dumped headers (see ApolloInlineImages.xm / ApolloInlineLinkPreviews.xm),
// so reuse that name here for consistency.
struct CDStruct_90e057aa { CGSize min; CGSize max; };

// Per-preview-node state. Stored as an associated NSNumber on the node.
typedef NS_ENUM(NSInteger, ApolloShareGalleryState) {
    ApolloShareGalleryStateNone = 0,   // not yet examined / not a gallery
    ApolloShareGalleryStatePlaceholder,// placeholder injected, fetch in flight
    ApolloShareGalleryStateApplied,    // real collage injected, leave ivars as-is
};

// Associated-object keys. The repo idiom is `static char kKey;` (no const, no
// initializer): only their addresses matter, and this form avoids any chance of
// identical-valued const objects being merged/aliased under -fmerge-all-constants.
static char kApolloShareGalleryStateKey;     // NSNumber(ApolloShareGalleryState)
static char kApolloShareGalleryCollageKey;   // strong UIImage (collage)
static char kApolloShareGalleryImageNodeKey; // strong ASImageNode

// Visual constants for the collage. Point dimensions; rendered at screen scale.
static const CGFloat kApolloShareGalleryContentWidth = 320.0;
static const CGFloat kApolloShareGalleryGap = 3.0;
static const CGFloat kApolloShareGalleryCornerRadius = 12.0;
static const NSInteger kApolloShareGalleryMaxVisible = 4; // beyond this -> "+N"

#pragma mark - Runtime ivar helpers

static id ApolloShareIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    id value = nil;
    @try { value = object_getIvar(obj, ivar); } @catch (__unused NSException *e) {}
    return value;
}

// Writes an object into a Swift STRONG ivar with balanced ARC ownership.
//
// object_setIvar() stores the raw pointer but does NOT add the +1 retain that a
// Swift `strong` ivar slot is expected to own. When the host object is later
// deallocated, Swift's deinit releases every strong ivar — including ours —
// which over-releases the value we stored and produces a delayed EXC_BAD_ACCESS.
//
// To balance that future release we CFRetain the new value (so the slot truly
// owns +1), and CFRelease whatever was already in the slot (we're taking over
// its ownership). This mirrors what an ARC strong-property setter does.
//
// NOTE: this balance intentionally relies on object_setIvar performing a RAW
// store (no ARC retain/release) for these Swift `strong` ivars, which holds
// while the runtime reports their memory management as "unknown". If a future
// Swift/ObjC runtime ever reports them as strong, object_setIvar would itself
// objc_storeStrong (retain new / release old), and the CFRetain/CFRelease here
// would over-release `previous`. Re-check this assumption if it ever regresses
// across iOS versions.
static void ApolloShareSetIvarObject(id obj, const char *name, id value) {
    if (!obj || !name) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return;
    @try {
        id previous = object_getIvar(obj, ivar);
        if (value) CFRetain((__bridge CFTypeRef)value);   // slot now owns +1 on the new value
        object_setIvar(obj, ivar, value);
        if (previous) CFRelease((__bridge CFTypeRef)previous); // release the value we replaced
    } @catch (__unused NSException *e) {}
}

// Swift Bool ivars are a single byte at the ivar offset; object_setIvar can't
// be used for non-object ivars, so write the byte directly.
static void ApolloShareSetIvarBool(id obj, const char *name, BOOL value) {
    if (!obj || !name) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return;
    // Safety here comes from the class_getInstanceVariable lookup above: a valid
    // Ivar guarantees an in-bounds offset for this object. A raw out-of-bounds
    // store would raise SIGSEGV/SIGBUS, which @try/@catch cannot intercept, so
    // there is no exception guard to add — the lookup is the real safeguard.
    ptrdiff_t offset = ivar_getOffset(ivar);
    unsigned char *base = (unsigned char *)(__bridge void *)obj;
    base[offset] = value ? 1 : 0;
}

// Reads a Swift Bool ivar (a single byte at the ivar offset). Returns NO when the
// ivar is missing. Mirror of ApolloShareSetIvarBool's offset math.
static BOOL ApolloShareIvarBool(id obj, const char *name) {
    if (!obj || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    const unsigned char *base = (const unsigned char *)(__bridge const void *)obj;
    return base[offset] != 0;
}

#pragma mark - Gallery model extraction

// Pulls the ordered list of still-image URLs out of an RDKLink's gallery.
// Uses internalGallery.items[].image.url. Video items still expose a static
// poster via .url, so we use that for every tile. Returns nil if not a
// multi-image gallery.
static NSArray<NSURL *> *ApolloShareGalleryImageURLs(id link) {
    if (!link) return nil;

    id gallery = nil;
    @try {
        if ([link respondsToSelector:@selector(internalGallery)]) {
            gallery = [link performSelector:@selector(internalGallery)];
        }
    } @catch (__unused NSException *e) {}
    if (!gallery) return nil;

    id items = nil;
    @try {
        if ([gallery respondsToSelector:@selector(items)]) {
            items = [gallery performSelector:@selector(items)];
        }
    } @catch (__unused NSException *e) {}
    if (![items isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id item in (NSArray *)items) {
        id image = nil;
        @try {
            if ([item respondsToSelector:@selector(image)]) {
                image = [item performSelector:@selector(image)];
            }
        } @catch (__unused NSException *e) {}
        id url = nil;
        @try {
            if (image && [image respondsToSelector:@selector(url)]) {
                url = [image performSelector:@selector(url)];
            }
        } @catch (__unused NSException *e) {}
        if ([url isKindOfClass:[NSURL class]]) {
            [urls addObject:(NSURL *)url];
        }
    }

    return urls.count >= 2 ? urls : nil;
}

#pragma mark - Single-poster (video / spoiler / NSFW) model extraction

// Calls a 0-arg selector returning an object, guarded. Returns nil on miss.
static id ApolloShareCall(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    id result = nil;
    @try {
        result = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) {}
    return result;
}

// Calls a 0-arg selector returning a BOOL, guarded.
static BOOL ApolloShareCallBool(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) { return NO; }
}

// YES if the link is a video post (direct or crossposted).
static BOOL ApolloShareLinkHasVideo(id link) {
    if (!link) return NO;
    if (ApolloShareCall(link, @selector(video))) return YES;
    if (ApolloShareCall(link, @selector(mediaVideo))) return YES;
    if (ApolloShareCall(link, @selector(previewVideo))) return YES;
    id parent = ApolloShareCall(link, @selector(crosspostParent));
    if (parent && parent != link) {
        if (ApolloShareCall(parent, @selector(video))) return YES;
        if (ApolloShareCall(parent, @selector(mediaVideo))) return YES;
    }
    return NO;
}

// YES if the link is obscured (spoiler or NSFW) — the cases where Apollo hides
// the media behind an overlay and we instead want the underlying still.
static BOOL ApolloShareLinkIsObscured(id link) {
    if (!link) return NO;
    if (ApolloShareCallBool(link, @selector(isSpoiler))) return YES;
    if (ApolloShareCallBool(link, @selector(spoiler))) return YES;
    if (ApolloShareCallBool(link, @selector(isNSFW))) return YES;
    if (ApolloShareCallBool(link, @selector(NSFW))) return YES;
    return NO;
}

// Resolves the best still-image URL for a non-gallery media post: the preview
// media's full-resolution source image, falling back to the low-res
// thumbnailURL. Also tries the crosspost parent. Returns nil if none.
static NSURL *ApolloShareResolvePosterURL(id link) {
    if (!link) return nil;

    id candidates[2] = { link, ApolloShareCall(link, @selector(crosspostParent)) };
    for (int i = 0; i < 2; i++) {
        id src = candidates[i];
        if (!src) continue;

        // previewMedia.sourceImage.URL — the real (un-obscured) source still.
        id previewMedia = ApolloShareCall(src, @selector(previewMedia));
        id sourceImage = ApolloShareCall(previewMedia, @selector(sourceImage));
        id url = ApolloShareCall(sourceImage, @selector(URL));
        if ([url isKindOfClass:[NSURL class]]) return (NSURL *)url;
    }

    // Fallback: low-res thumbnail.
    id thumb = ApolloShareCall(link, @selector(thumbnailURL));
    if ([thumb isKindOfClass:[NSURL class]]) {
        NSURL *t = (NSURL *)thumb;
        // Reddit uses sentinel strings ("default", "spoiler", "nsfw", "self")
        // instead of real URLs when there's no thumbnail.
        if (t.scheme.length > 0) return t;
    }
    return nil;
}

#pragma mark - Image fetch

// Fetches every URL concurrently, preserving order. results[i] is a UIImage or
// NSNull on failure. Calls `done` on the main queue.
static void ApolloShareGalleryFetchImages(NSArray<NSURL *> *urls,
                                          void (^done)(NSArray *images)) {
    NSUInteger count = urls.count;
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [results addObject:[NSNull null]];
    }

    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];

    for (NSUInteger i = 0; i < count; i++) {
        NSURL *url = urls[i];
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:url
          completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            if (image) {
                @synchronized (lock) { results[i] = image; }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        done(results);
    });
}

#pragma mark - Collage rendering

// Draws `image` to fill `rect` (aspectFill, center-cropped). Caller sets the
// clip rect. If image is missing, fills with a neutral placeholder.
static void ApolloShareGalleryDrawAspectFill(UIImage *image, CGRect rect) {
    if (![image isKindOfClass:[UIImage class]] ||
        image.size.width <= 0.0 || image.size.height <= 0.0) {
        [[UIColor colorWithWhite:0.5 alpha:0.25] setFill];
        UIRectFill(rect);
        return;
    }

    CGFloat scale = MAX(rect.size.width / image.size.width,
                        rect.size.height / image.size.height);
    CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
    CGRect drawRect = CGRectMake(
        rect.origin.x + (rect.size.width - drawSize.width) / 2.0,
        rect.origin.y + (rect.size.height - drawSize.height) / 2.0,
        drawSize.width,
        drawSize.height);

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    [image drawInRect:drawRect];
    CGContextRestoreGState(ctx);
}

// Builds a feed-style collage from up to kApolloShareGalleryMaxVisible images.
// Layout: 2 columns of square cells. A lone trailing image (odd count) spans
// the full width. When totalCount exceeds the visible cap, a "+N" overlay is
// drawn on the last visible tile. Returns nil if nothing renderable.
static UIImage *ApolloShareGalleryRenderCollage(NSArray *images, NSInteger totalCount) {
    if (images.count == 0) return nil;

    NSInteger visible = MIN((NSInteger)images.count, kApolloShareGalleryMaxVisible);
    if (visible < 1) return nil;

    const CGFloat width = kApolloShareGalleryContentWidth;
    const CGFloat gap = kApolloShareGalleryGap;
    const NSInteger columns = 2;
    const CGFloat cellWidth = (width - gap * (columns - 1)) / columns;
    const CGFloat cellHeight = cellWidth; // square cells, feed-like

    NSInteger rows = (visible + columns - 1) / columns;
    CGFloat totalHeight = rows * cellHeight + (rows - 1) * gap;

    // Precompute each tile's frame.
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSInteger i = 0; i < visible; i++) {
        NSInteger row = i / columns;
        NSInteger col = i % columns;
        BOOL loneTrailing = (i == visible - 1) && (visible % columns == 1) && (col == 0);
        CGFloat x = col * (cellWidth + gap);
        CGFloat y = row * (cellHeight + gap);
        CGFloat w = loneTrailing ? width : cellWidth;
        CGRect frame = CGRectMake(x, y, w, cellHeight);
        [frames addObject:[NSValue valueWithCGRect:frame]];
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 2.0;

    CGSize canvas = CGSizeMake(width, totalHeight);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format];

    UIImage *collage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef ctx = rendererContext.CGContext;

        // Round the outer corners to match Apollo's media cards.
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, totalHeight)
                                                        cornerRadius:kApolloShareGalleryCornerRadius];
        CGContextSaveGState(ctx);
        [clip addClip];

        for (NSInteger i = 0; i < visible; i++) {
            CGRect frame = [frames[i] CGRectValue];
            id obj = images[i];
            UIImage *image = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            ApolloShareGalleryDrawAspectFill(image, frame);

            // "+N" overlay on the final visible tile when there are more.
            NSInteger remaining = totalCount - kApolloShareGalleryMaxVisible;
            if (i == visible - 1 && remaining > 0) {
                [[UIColor colorWithWhite:0.0 alpha:0.45] setFill];
                UIRectFillUsingBlendMode(frame, kCGBlendModeNormal);

                NSString *text = [NSString stringWithFormat:@"+%ld", (long)remaining];
                UIFont *font = [UIFont systemFontOfSize:cellHeight * 0.28
                                                 weight:UIFontWeightSemibold];
                NSDictionary *attrs = @{
                    NSFontAttributeName: font,
                    NSForegroundColorAttributeName: [UIColor whiteColor],
                };
                CGSize textSize = [text sizeWithAttributes:attrs];
                CGPoint textPoint = CGPointMake(
                    frame.origin.x + (frame.size.width - textSize.width) / 2.0,
                    frame.origin.y + (frame.size.height - textSize.height) / 2.0);
                [text drawAtPoint:textPoint withAttributes:attrs];
            }
        }

        CGContextRestoreGState(ctx);
    }];

    return collage;
}

// Renders a single still (video poster / spoiler image) as a full-width,
// aspect-preserving, rounded-corner image to match Apollo's media card look.
// Pass image == nil to draw a neutral grey placeholder at `aspect` (falls back
// to 16:9 when aspect is unknown).
static UIImage *ApolloShareGalleryRenderSingle(UIImage *image, CGSize aspect) {
    const CGFloat width = kApolloShareGalleryContentWidth;

    CGFloat ratio;
    if (image && image.size.width > 0.0 && image.size.height > 0.0) {
        ratio = image.size.height / image.size.width;
    } else if (aspect.width > 0.0 && aspect.height > 0.0) {
        ratio = aspect.height / aspect.width;
    } else {
        ratio = 9.0 / 16.0; // default landscape video poster
    }
    // Clamp to a sane card height range so tall/pano stills don't explode.
    ratio = MAX(0.3, MIN(ratio, 1.6));
    CGFloat height = round(width * ratio);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 2.0;

    CGSize canvas = CGSizeMake(width, height);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef ctx = rendererContext.CGContext;
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, height)
                                                        cornerRadius:kApolloShareGalleryCornerRadius];
        CGContextSaveGState(ctx);
        [clip addClip];
        ApolloShareGalleryDrawAspectFill(image, CGRectMake(0, 0, width, height));
        CGContextRestoreGState(ctx);
    }];
}

#pragma mark - Apply / relayout

// Installs `image` into the preview node via Apollo's own single-image path and
// requests a relayout. MUST run on the main thread (it creates an ASImageNode
// and mutates the node tree). `isFinal` only affects the stored state and log.
//
// We keep strong associated refs to both the image and the ASImageNode so that,
// even with the balanced ivar retain in ApolloShareSetIvarObject, nothing we
// created is reclaimed out from under Apollo's layout between passes.
static void ApolloShareGalleryInstallImage(id previewNode, UIImage *image, BOOL isFinal) {
    if (!previewNode || ![image isKindOfClass:[UIImage class]]) return;

    objc_setAssociatedObject(previewNode, &kApolloShareGalleryCollageKey, image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Build an ASImageNode for the image and route it through both the
    // imageForImagePost ivar (Apollo's single-image trigger) and the imageNode
    // ivar (the node the layout spec lays out). Setting both maximises the
    // chance the native layout spec includes the image regardless of which it
    // keys off.
    Class imageNodeClass = objc_getClass("ASImageNode");
    id imageNode = nil;
    if (imageNodeClass) {
        @try {
            imageNode = [[imageNodeClass alloc] init];
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(imageNode, @selector(setImage:), image);
            if ([imageNode respondsToSelector:@selector(setContentMode:)]) {
                ((void (*)(id, SEL, UIViewContentMode))objc_msgSend)(
                    imageNode, @selector(setContentMode:), UIViewContentModeScaleAspectFit);
            }
        } @catch (__unused NSException *e) { imageNode = nil; }
    }
    if (imageNode) {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryImageNodeKey, imageNode,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloShareSetIvarObject(previewNode, "imageNode", imageNode);
    }

    ApolloShareSetIvarObject(previewNode, "imageForImagePost", image);
    ApolloShareSetIvarBool(previewNode, "includePostTextPollOrImage", YES);
    // Drop the compact link card so only the collage shows. Cleared through the
    // balanced helper so the old node's ownership is released, not leaked.
    ApolloShareSetIvarObject(previewNode, "linkButtonNode", nil);

    objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                             @(isFinal ? ApolloShareGalleryStateApplied
                                       : ApolloShareGalleryStatePlaceholder),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Request a fresh layout pass; the ShareAsImageViewController re-snapshots
    // the preview, so the exported image picks up the image too.
    @try {
        if ([previewNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(invalidateCalculatedLayout));
        }
        if ([previewNode respondsToSelector:@selector(setNeedsLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(setNeedsLayout));
        }
        if ([previewNode respondsToSelector:@selector(_u_setNeedsLayoutFromAbove)]) {
            ((void (*)(id, SEL))objc_msgSend)(previewNode, @selector(_u_setNeedsLayoutFromAbove));
        }
    } @catch (__unused NSException *e) {}

    ApolloLog(@"[ShareGallery] %@ image installed node=%p size=%@",
              isFinal ? @"final" : @"placeholder", previewNode,
              NSStringFromCGSize(image.size));
}

// Hops to the main thread (or runs immediately if already there) before
// installing — node-tree mutation must not happen on Texture's background
// layout thread.
static void ApolloShareGalleryInstallImageOnMain(id previewNode, UIImage *image, BOOL isFinal) {
    if (!previewNode || !image) return;
    if ([NSThread isMainThread]) {
        ApolloShareGalleryInstallImage(previewNode, image, isFinal);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloShareGalleryInstallImage(previewNode, image, isFinal);
        });
    }
}

// Builds a neutral grey placeholder collage with the same geometry the real
// collage will use, so the first visible frame already shows the gallery grid
// (never Apollo's compact link card) while the real images download.
static UIImage *ApolloShareGalleryRenderPlaceholder(NSInteger totalCount) {
    NSInteger visible = MIN(totalCount, kApolloShareGalleryMaxVisible);
    if (visible < 1) return nil;
    NSMutableArray *blanks = [NSMutableArray arrayWithCapacity:visible];
    for (NSInteger i = 0; i < visible; i++) [blanks addObject:[NSNull null]];
    // RenderCollage draws a neutral fill for NSNull tiles and keeps geometry.
    return ApolloShareGalleryRenderCollage(blanks, totalCount);
}

// Reads a 0-arg selector returning a double, guarded.
static double ApolloShareCallDouble(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return 0.0;
    @try {
        return ((double (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) { return 0.0; }
}

// Returns the source-image aspect (width,height) for a non-gallery media post,
// or CGSizeZero when unknown. Used to size the single-still placeholder.
static CGSize ApolloShareResolvePosterAspect(id link) {
    id candidates[2] = { link, ApolloShareCall(link, @selector(crosspostParent)) };
    for (int i = 0; i < 2; i++) {
        id src = candidates[i];
        if (!src) continue;
        id previewMedia = ApolloShareCall(src, @selector(previewMedia));
        id sourceImage = ApolloShareCall(previewMedia, @selector(sourceImage));
        if (sourceImage) {
            double w = ApolloShareCallDouble(sourceImage, @selector(width));
            double h = ApolloShareCallDouble(sourceImage, @selector(height));
            if (w > 0.0 && h > 0.0) return CGSizeMake(w, h);
        }
    }
    return CGSizeZero;
}

// Handles the single-still cases (video posts, spoiler/NSFW media) where Apollo
// leaves imageForImagePost nil and falls back to the compact link card. Fetches
// the post's poster/source still and installs it (un-obscured) as a full-width
// rounded image. Leaves genuine text/self/external-link posts untouched.
static void ApolloShareGalleryPrepareSingle(id previewNode, id link) {
    // Only act on cards Apollo didn't fill itself — never override a real image.
    if (ApolloShareIvarObject(previewNode, "imageForImagePost") != nil) {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStateApplied),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // External hosted video (Streamable / Redgifs): these carry no RDKVideo, so
    // ApolloShareLinkHasVideo is NO and Apollo shows its compact link card with the
    // host's scraped title (e.g. "Watch ssstwitter…"). Resolve the poster + true
    // size from the host API and install it full-width — dropping the link card —
    // so the share card matches the post. ApolloShareAsVideo then composites the
    // clip over this correctly-sized still (no crop). Resolution is async (an API
    // call), unlike the native poster path below, so it has its own flow.
    NSURL *linkURL = (NSURL *)ApolloShareCall(link, @selector(URL));
    if (ApolloHostedVideoKindForURL(linkURL) != ApolloHostedVideoNone) {
        // Re-entrancy guard: flip to Placeholder synchronously before async work, so
        // repeated background layout passes don't launch duplicate resolves.
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStatePlaceholder),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Smooth the first frame: drop the compact link card IMMEDIATELY with a
        // neutral placeholder, BEFORE the async host-API poster resolve, so the
        // junk-titled link card never flashes. Size it from Reddit's own scraped
        // preview aspect when available (previewMedia/thumbnail) so there's no
        // reflow; the host API then confirms the exact aspect + supplies the still.
        CGSize syncAspect = ApolloShareResolvePosterAspect(link);
        UIImage *immediate = ApolloShareGalleryRenderSingle(nil, syncAspect);
        if (immediate) ApolloShareGalleryInstallImageOnMain(previewNode, immediate, NO);
        ApolloLog(@"[ShareGallery] hosted video node=%p url=%@ syncAspect=%@ — placeholder + resolve",
                  previewNode, linkURL.absoluteString, NSStringFromCGSize(syncAspect));
        __weak id weakNode = previewNode;
        ApolloHostedVideoResolve(linkURL, ^(__unused NSURL *mp4, NSURL *posterURL,
                                            CGSize pixelSize, __unused BOOL hasAudio) {
            id strongNode = weakNode;
            if (!strongNode) return;
            if (!posterURL) {
                // No poster resolvable — leave Apollo's native card untouched.
                objc_setAssociatedObject(strongNode, &kApolloShareGalleryStateKey,
                                         @(ApolloShareGalleryStateApplied),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return;
            }
            CGSize aspect = (pixelSize.width > 0 && pixelSize.height > 0) ? pixelSize : CGSizeZero;
            // Placeholder immediately (correct aspect) so the link card doesn't linger.
            UIImage *placeholder = ApolloShareGalleryRenderSingle(nil, aspect);
            if (placeholder) ApolloShareGalleryInstallImageOnMain(strongNode, placeholder, NO);
            ApolloShareGalleryFetchImages(@[posterURL], ^(NSArray *images) {
                id n2 = weakNode;
                if (!n2) return;
                UIImage *fetched = nil;
                for (id img in images) {
                    if ([img isKindOfClass:[UIImage class]]) { fetched = (UIImage *)img; break; }
                }
                UIImage *single = fetched ? ApolloShareGalleryRenderSingle(fetched, aspect) : nil;
                ApolloLog(@"[ShareGallery] hosted poster fetch node=%p ok=%d", n2, fetched != nil);
                if (single) {
                    ApolloShareGalleryInstallImageOnMain(n2, single, YES);
                } else {
                    objc_setAssociatedObject(n2, &kApolloShareGalleryStateKey,
                                             @(ApolloShareGalleryStateApplied),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
        });
        return;
    }

    BOOL hasVideo = ApolloShareLinkHasVideo(link);
    BOOL obscured = ApolloShareLinkIsObscured(link);
    NSURL *posterURL = (hasVideo || obscured) ? ApolloShareResolvePosterURL(link) : nil;
    if (!posterURL) {
        // Genuine link/text/self post (or no still available): keep the card.
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStateApplied),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGSize aspect = ApolloShareResolvePosterAspect(link);
    ApolloLog(@"[ShareGallery] single poster node=%p video=%d obscured=%d url=%@ — placeholder + fetch",
              previewNode, hasVideo, obscured, posterURL.absoluteString);

    // Close the re-entrancy window (see ApolloShareGalleryPrepare): flip the
    // state to Placeholder synchronously, on this (background layout) thread,
    // BEFORE the async install + fetch. Associated-object writes are thread-safe.
    objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                             @(ApolloShareGalleryStatePlaceholder),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Install a placeholder immediately so the link card never flashes.
    UIImage *placeholder = ApolloShareGalleryRenderSingle(nil, aspect);
    if (placeholder) {
        ApolloShareGalleryInstallImageOnMain(previewNode, placeholder, NO);
    } else {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStatePlaceholder),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    __weak id weakNode = previewNode;
    ApolloShareGalleryFetchImages(@[posterURL], ^(NSArray *images) {
        id strongNode = weakNode;
        if (!strongNode) return;

        UIImage *fetched = nil;
        for (id img in images) {
            if ([img isKindOfClass:[UIImage class]]) { fetched = (UIImage *)img; break; }
        }
        UIImage *single = fetched ? ApolloShareGalleryRenderSingle(fetched, aspect) : nil;
        ApolloLog(@"[ShareGallery] single fetch complete node=%p ok=%d image=%@",
                  strongNode, fetched != nil, single ? @"built" : @"nil");
        if (single) {
            ApolloShareGalleryInstallImageOnMain(strongNode, single, YES);
        } else {
            objc_setAssociatedObject(strongNode, &kApolloShareGalleryStateKey,
                                     @(ApolloShareGalleryStateApplied),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

// Examines a preview node once: if it's a gallery, immediately installs a
// placeholder grid (so the link card never flashes), then fetches the real
// images and swaps in the finished collage. Non-gallery video/spoiler/NSFW
// media is routed to the single-still handler. Safe to call repeatedly
// (state-guarded) and from Texture's background layout thread.
static void ApolloShareGalleryPrepare(id previewNode) {
    if (!previewNode) return;

    NSNumber *stateNum = objc_getAssociatedObject(previewNode, &kApolloShareGalleryStateKey);
    ApolloShareGalleryState state = stateNum ? (ApolloShareGalleryState)stateNum.integerValue
                                             : ApolloShareGalleryStateNone;
    if (state == ApolloShareGalleryStateApplied) {
        // Toggling a preview option (e.g. "Include Post Details") makes Apollo
        // rebuild the node and RESET imageForImagePost/linkButtonNode back to its
        // native compact link card. Our state is still "Applied", so without this
        // the collage would be lost and the compact card would show. Re-assert the
        // cached collage when we detect the reset. Comment / non-gallery shares
        // never cache a collage, so they no-op here.
        //
        // But only while the post media is actually being shown: if the user has
        // since turned "Include Post Details" (and "Include Post Text, Poll, or
        // Image") back OFF on a comment share, the preview is meant to be the bare
        // comment, so re-injecting would leak the post collage back in. Re-using the
        // same condition as the bail check below keeps the two in lock-step.
        BOOL postMediaShown = (ApolloShareIvarObject(previewNode, "comment") == nil) ||
                              ApolloShareIvarBool(previewNode, "includePostDetails") ||
                              ApolloShareIvarBool(previewNode, "includePostTextPollOrImage");
        UIImage *cached = objc_getAssociatedObject(previewNode, &kApolloShareGalleryCollageKey);
        if (postMediaShown &&
            [cached isKindOfClass:[UIImage class]] &&
            ApolloShareIvarObject(previewNode, "imageForImagePost") == nil) {
            ApolloLog(@"[ShareGallery] collage reset by a toggle, re-injecting cached image");
            ApolloShareGalleryInstallImageOnMain(previewNode, cached, YES);
        }
        return;
    }
    if (state != ApolloShareGalleryStateNone) return; // placeholder in flight

    // Comment-share mode: when the user is sharing a COMMENT (not the post), the
    // shared image is normally just the comment, so we must NOT touch the post's
    // media — injecting imageForImagePost there is what made the post's gallery
    // image leak into a plain comment share.
    //
    // EXCEPTION: when the user shows the underlying post above the comment, Apollo
    // ALSO renders the post's media region — and for a gallery/video/spoiler post
    // that region falls back to Apollo's compact link card (imageForImagePost stays
    // nil), exactly as it does for a post share. In that case we DO want to inject
    // the collage/poster into the post media region; the comment itself
    // (baseCommentNode) is laid out separately and is left untouched.
    //
    // Two distinct node flags can request the post media in comment mode, and they
    // map to two different sheet toggles: "Include Post Details" (includePostDetails)
    // and "Include Post Text, Poll, or Image" (includePostTextPollOrImage). The sheet
    // surfaces one or the other depending on context, so we must honour BOTH —
    // checking only includePostTextPollOrImage left "Include Post Details" gallery
    // shares falling back to the compact link card (#551 follow-up). Only bail when
    // the post media is NOT being shown by either flag.
    //
    // CRUCIAL: do NOT mark the node Applied on this bail. The sheet opens with post
    // details OFF, so this gate is the FIRST thing that fires for every comment
    // share — caching "Applied" here would lock the node, and because Apollo reuses
    // the same preview node when the user later toggles "Include Post Details" ON,
    // we'd never re-examine it and the compact link card would stay stuck (the
    // collage only appeared before when Apollo happened to rebuild the node — racy).
    // Leaving the state untouched (None) makes each layout pass re-check, so the
    // collage is injected the moment post media is turned on. The check is cheap
    // (ivar reads) and no network fetch starts until a gallery is actually detected.
    if (ApolloShareIvarObject(previewNode, "comment") != nil &&
        !ApolloShareIvarBool(previewNode, "includePostTextPollOrImage") &&
        !ApolloShareIvarBool(previewNode, "includePostDetails")) {
        return;
    }

    id link = ApolloShareIvarObject(previewNode, "link");
    NSArray<NSURL *> *urls = ApolloShareGalleryImageURLs(link);
    if (urls.count < 2) {
        // Not a multi-image gallery — try the single-still path (video /
        // spoiler / NSFW). That handler decides whether to act or leave the
        // card and sets the state accordingly.
        ApolloShareGalleryPrepareSingle(previewNode, link);
        return;
    }

    NSInteger totalCount = (NSInteger)urls.count;
    ApolloLog(@"[ShareGallery] gallery detected node=%p items=%ld — placeholder + fetch",
              previewNode, (long)totalCount);

    // Close the re-entrancy window: flip to Placeholder synchronously here,
    // BEFORE dispatching the install or starting the fetch.
    // ApolloShareGalleryInstallImageOnMain also writes this state, but it does
    // so asynchronously on the main queue; layoutSpecThatFits: runs on Texture's
    // background layout threads and can fire several times in quick succession,
    // so without this synchronous write a second pass could slip past the state
    // guard at the top and launch a duplicate ApolloShareGalleryFetchImages
    // (N more network requests). objc_setAssociatedObject is thread-safe.
    objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                             @(ApolloShareGalleryStatePlaceholder),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Install the placeholder grid right away so the compact link card is never
    // shown.
    UIImage *placeholder = ApolloShareGalleryRenderPlaceholder(totalCount);
    if (placeholder) {
        ApolloShareGalleryInstallImageOnMain(previewNode, placeholder, NO);
    } else {
        objc_setAssociatedObject(previewNode, &kApolloShareGalleryStateKey,
                                 @(ApolloShareGalleryStatePlaceholder),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    __weak id weakNode = previewNode;
    ApolloShareGalleryFetchImages(urls, ^(NSArray *images) {
        id strongNode = weakNode;
        if (!strongNode) return;

        NSInteger ok = 0;
        for (id img in images) { if ([img isKindOfClass:[UIImage class]]) ok++; }

        UIImage *collage = ApolloShareGalleryRenderCollage(images, totalCount);
        ApolloLog(@"[ShareGallery] fetch complete node=%p ok=%ld/%ld collage=%@",
                  strongNode, (long)ok, (long)totalCount, collage ? @"built" : @"nil");
        if (collage) {
            ApolloShareGalleryInstallImageOnMain(strongNode, collage, YES);
        } else {
            // Couldn't build anything; keep the placeholder and mark applied.
            objc_setAssociatedObject(strongNode, &kApolloShareGalleryStateKey,
                                     @(ApolloShareGalleryStateApplied),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

#pragma mark - Hooks

%hook _TtC6Apollo22SaveAsImagePreviewNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    ApolloShareGalleryPrepare(self);
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo22SaveAsImagePreviewNode")) {
            %init();
            ApolloLog(@"[ShareGallery] module loaded");
        } else {
            ApolloLog(@"[ShareGallery] SaveAsImagePreviewNode not found — skipping");
        }
    }
}
