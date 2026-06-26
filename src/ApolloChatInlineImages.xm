// ApolloChatInlineImages.xm
//
// Feature 1 of the chat upgrade: render image messages inline in DM/chat bubbles.
//
// Apollo's chat is Reddit private messages (kind=t4, subject "[direct chat room]")
// rendered by a MessageKit fork. An image message arrives as markdown text
//   sent an image
// where "image" is a link, stored on the rendered messageLabel under Apollo's
// custom `ApolloLink` attribute, pointing at the Matrix-hosted media:
//   https://matrix.redditspace.com/_matrix/media/v3/download/reddit.com/<id>
// Apollo never builds a MessageKind.photo for these, so they show as text + link.
//
// Strategy (pure ObjC): post-process the cell the data source returns. Read the
// rendered messageLabel.attributedText, pull the image URL out of its ApolloLink
// attribute, load the image, paint it into the bubble, and grow the bubble to the
// image's aspect ratio by overriding the MessageKit layout attributes'
// `messageContainerSize` (so MessageKit positions/aligns the bubble itself).

#import "ApolloCommon.h"
#import "ApolloUserProfileCache.h"
#import "ApolloState.h"
#import "ApolloImageChestResolver.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- diagnostics toggle ----------------------------------------------------
// Off by default; flip to 1 for verbose per-render snoomoji/image/tap tracing.
#define APOLLO_CHAT_IMG_DEBUG 0
#if APOLLO_CHAT_IMG_DEBUG
  #define ChatImgLog(fmt, ...) ApolloLog(@"[ChatImg] " fmt, ##__VA_ARGS__)
#else
  #define ChatImgLog(fmt, ...) do {} while (0)
#endif

// Associated-object keys.
static char kApolloChatImgViewKey;       // on cell: our injected UIImageView
static char kApolloChatIvMediaKey;       // on the image view: the media (UIImage/FLAnimatedImage) it shows
static char kApolloChatContainerTapKey;  // on the bubble container: tap-to-fullscreen recognizer added
static char kApolloChatStickerInsetKey;  // on the image view: NSNumber inset (snoomoji art breathing room)
static char kApolloChatImgURLKey;        // on cell: NSString URL currently shown (reuse guard)
static char kApolloChatImgMediaSizeKey;  // on cell: NSValue CGSize of the rendered bubble
static char kApolloChatImgSizeMapKey;    // on VC:  NSMutableDictionary "section.item" -> NSValue CGSize
static char kApolloChatAvatarUserKey;    // on cell: NSString author we've stamped an avatar for

// Bubble sizing bounds.
static const CGFloat kApolloChatImgMaxWidth  = 232.0;
static const CGFloat kApolloChatImgMaxHeight = 320.0;
static const CGFloat kApolloChatImgMinWidth  = 120.0;

#pragma mark - URL helpers

static BOOL ApolloChatIsImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    NSString *ext = path.pathExtension;
    NSString *query = url.query.lowercaseString ?: @"";
    if ([query containsString:@"format=mp4"]) return NO;
    // Reddit chat media is served from the Matrix homeserver with no file extension:
    //   https://matrix.redditspace.com/_matrix/media/v3/download/reddit.com/<mediaId>
    if ([host containsString:@"matrix.redditspace.com"] && [path containsString:@"/_matrix/media/"]) {
        return YES;
    }
    if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
        [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"webp"] ||
        [ext isEqualToString:@"gif"]) {
        return YES;
    }
    static NSArray *imageHosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageHosts = @[@"i.redd.it", @"preview.redd.it", @"external-preview.redd.it",
                       @"i.imgur.com", @"reddit-uploaded-media", @"redditmedia.com"];
    });
    for (NSString *h in imageHosts) if ([host containsString:h]) return YES;
    return NO;
}

// Pull the first inline-image URL out of a rendered messageLabel's attributed text.
static NSURL *ApolloChatImageURLFromAttributed(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]] || attr.length == 0) return nil;
    __block NSURL *found = nil;
    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length) options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        for (NSAttributedStringKey key in attrs) {
            id val = attrs[key];
            NSURL *u = nil;
            if ([val isKindOfClass:[NSURL class]]) u = val;
            else if ([val isKindOfClass:[NSString class]] && [(NSString *)val hasPrefix:@"http"]) u = [NSURL URLWithString:val];
            if (u && (ApolloChatIsImageURL(u) || ApolloImageChestIsPostURL(u))) { found = u; *stop = YES; return; }
        }
    }];
    return found;
}

// Pull the direct CDN image URL out of an ImageChest resolver result (single image, or first of album).
static NSURL *ApolloChatDirectURLFromImageChest(NSDictionary *res) {
    if (![res isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *imgs = [res[@"images"] isKindOfClass:[NSArray class]] ? res[@"images"] : nil;
    id first = imgs.firstObject;
    if ([first isKindOfClass:[NSDictionary class]] && [first[@"url"] isKindOfClass:[NSURL class]]) return first[@"url"];
    if ([res[@"url"] isKindOfClass:[NSURL class]]) return res[@"url"];
    return nil;
}

#pragma mark - ivar access

static UILabel *ApolloChatMessageLabel(id cell) {
    if (!cell) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(cell), "messageLabel");
    if (!iv) return nil;
    id label = object_getIvar(cell, iv);
    return [label isKindOfClass:[UILabel class]] ? label : nil;
}

static UIView *ApolloChatContainerView(id cell) {
    if (!cell) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(cell), "messageContainerView");
    if (!iv) return nil;
    id v = object_getIvar(cell, iv);
    return [v isKindOfClass:[UIView class]] ? v : nil;
}

// Write a CGSize-typed struct ivar by name (object_getIvar can't touch struct ivars).
static void ApolloChatSetCGSizeIvar(id obj, const char *name, CGSize sz) {
    if (!obj || !name) return;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return;
    ptrdiff_t off = ivar_getOffset(iv);
    char *base = (char *)(__bridge void *)obj;
    *(CGSize *)(base + off) = sz;
}

// Read a CGSize-typed struct ivar by name.
static CGSize ApolloChatGetCGSizeIvar(id obj, const char *name) {
    if (!obj || !name) return CGSizeZero;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return CGSizeZero;
    return *(CGSize *)((char *)(__bridge void *)obj + ivar_getOffset(iv));
}

static NSString *ApolloChatIndexKey(NSIndexPath *ip) {
    return [NSString stringWithFormat:@"%ld.%ld", (long)ip.section, (long)ip.item];
}

static NSMutableDictionary *ApolloChatSizeMap(id vc) {
    NSMutableDictionary *m = objc_getAssociatedObject(vc, &kApolloChatImgSizeMapKey);
    if (!m) { m = [NSMutableDictionary dictionary]; objc_setAssociatedObject(vc, &kApolloChatImgSizeMapKey, m, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return m;
}

// Aspect-correct bubble size for a decoded image, clamped to our bounds.
static CGSize ApolloChatMediaSize(UIImage *img) {
    CGFloat iw = img.size.width, ih = img.size.height;
    if (iw <= 0 || ih <= 0) return CGSizeMake(200, 150);
    CGFloat aspect = ih / iw;
    CGFloat w = kApolloChatImgMaxWidth;
    CGFloat h = w * aspect;
    if (h > kApolloChatImgMaxHeight) { h = kApolloChatImgMaxHeight; w = h / aspect; }
    if (w < kApolloChatImgMinWidth)  { w = kApolloChatImgMinWidth;  h = w * aspect; if (h > kApolloChatImgMaxHeight) h = kApolloChatImgMaxHeight; }
    return CGSizeMake(floor(w), floor(h));
}

// Size a sticker by a fixed HEIGHT (not the longest side) so every one stands the same tall
// regardless of how many emoji or their aspect — sender and receiver match. Width follows aspect,
// clamped so a long emoji run can't overflow the bubble. Unicode emoji use a small (text-emoji)
// height; Reddit snoomoji art uses a larger sticker height. (kApolloChatUnicodeEmojiHeight /
// kApolloChatSnoomojiHeight)
static CGSize ApolloChatStickerSize(UIImage *img, CGFloat targetH) {
    CGFloat iw = img.size.width, ih = img.size.height;
    if (iw <= 0 || ih <= 0) return CGSizeMake(targetH, targetH);
    static const CGFloat maxW = 200.0;
    CGFloat scale = targetH / ih;
    CGFloat w = iw * scale, h = targetH;
    if (w > maxW) { scale = maxW / iw; w = maxW; h = ih * scale; }   // very wide run: clamp width
    return CGSizeMake(floor(w), floor(h));
}
static const CGFloat kApolloChatUnicodeEmojiHeight = 46.0;   // 👍 — matches the iOS emoji-keyboard glyph size
static const CGFloat kApolloChatSnoomojiHeight     = 74.0;   // snoo art — larger sticker (bubble incl. inset)
static const CGFloat kApolloChatSnoomojiInset      = 9.0;    // breathing room so the snoo art isn't edge-cramped

#pragma mark - gif-aware media loader

// Apollo bundles Flipboard's FLAnimatedImage (FLAnimatedImage + FLAnimatedImageView,
// a UIImageView subclass). We render gif messages with it so they animate; static
// images use the same view's -image. Resolved at runtime to avoid a link dependency.
static Class ApolloFLAnimatedImageClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = objc_getClass("FLAnimatedImage"); });
    return c;
}
static Class ApolloFLAnimatedImageViewClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = objc_getClass("FLAnimatedImageView"); });
    return c;
}

// url -> loaded media (an FLAnimatedImage for animated gifs, else a UIImage).
static NSMutableDictionary *ApolloChatMediaCache(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// Draw a (possibly multi-codepoint) emoji string into a transparent image. Used to render a
// pure-emoji message as a sticker overlay — Apollo "jumbo-blanks" a lone-emoji bubble and its
// TextKit-backed MessageLabel won't reliably draw an enlarged glyph we set, so we rasterize.
static UIImage *ApolloChatRasterizeEmoji(NSString *emoji) {
    if (emoji.length == 0) return nil;
    // Render at high res (down-samples crisply), with ~22% transparent padding each side so the
    // glyph sits at ≈70% of the sticker — matching Reddit snoomoji art padding, so a lone emoji
    // isn't oversized and never touches the rounded bubble edge.
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:80.0] };
    CGSize glyph = [emoji sizeWithAttributes:attrs];
    if (glyph.width < 1.0 || glyph.height < 1.0) return nil;
    CGFloat padX = glyph.width * 0.22, padY = glyph.height * 0.22;
    CGSize canvas = CGSizeMake(glyph.width + padX * 2, glyph.height + padY * 2);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO; fmt.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [emoji drawAtPoint:CGPointMake(padX, padY) withAttributes:attrs];
    }];
}

// Rasterize a pure-emoji body and stash it in the media cache under a synthetic URL, so the normal
// image-overlay path (cache hit -> sticker size -> reflow) renders it with zero network work.
static NSURL *ApolloChatEmojiStickerURL(NSString *emoji) {
    if (emoji.length == 0) return nil;
    NSString *enc = [emoji stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
    NSURL *url = enc.length ? [NSURL URLWithString:[@"x-apollo-emoji:///" stringByAppendingString:enc]] : nil;
    if (!url) return nil;
    NSString *key = url.absoluteString;
    if (!ApolloChatMediaCache()[key]) {
        UIImage *img = ApolloChatRasterizeEmoji(emoji);
        if (!img) return nil;
        ApolloChatMediaCache()[key] = img;
    }
    return url;
}

static BOOL ApolloDataIsGIF(NSData *d) {
    if (d.length < 6) return NO;
    const unsigned char *b = (const unsigned char *)d.bytes;
    return b[0] == 'G' && b[1] == 'I' && b[2] == 'F';   // GIF87a / GIF89a
}

// Put either an animated gif or a static image on the (FLAnimatedImageView) media view.
static void ApolloChatSetMedia(UIImageView *iv, id media) {
    if (!iv || !media) return;
    // Keep a direct handle to the media so the tap-to-fullscreen handler doesn't have to read it
    // back through FLAnimatedImageView's image/animatedImage getters (unreliable for static images).
    objc_setAssociatedObject(iv, &kApolloChatIvMediaKey, media, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Class fl = ApolloFLAnimatedImageClass();
    if (fl && [media isKindOfClass:fl]) {
        // FLAnimatedImageView setter; clearing -image first avoids a stale poster frame.
        iv.image = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(iv, @selector(setAnimatedImage:), media);
    } else if ([media isKindOfClass:[UIImage class]]) {
        // ensure any previously-set animatedImage is cleared
        if ([iv respondsToSelector:@selector(setAnimatedImage:)])
            ((void (*)(id, SEL, id))objc_msgSend)(iv, @selector(setAnimatedImage:), nil);
        iv.image = media;
    }
}

// Stop + clear any media on the view (both static image and the animated gif), so a
// recycled cell doesn't keep an old gif animating or flash a stale frame.
static void ApolloChatClearMedia(UIImageView *iv) {
    if (!iv) return;
    objc_setAssociatedObject(iv, &kApolloChatIvMediaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    iv.image = nil;
    if ([iv respondsToSelector:@selector(setAnimatedImage:)])
        ((void (*)(id, SEL, id))objc_msgSend)(iv, @selector(setAnimatedImage:), nil);
}

// Fetch raw bytes once (cached), sniff the gif magic, and hand back an FLAnimatedImage
// (animated) or a decoded UIImage (static). Completion runs on the main queue.
static void ApolloChatLoadMedia(NSURL *url, void (^completion)(id media)) {
    NSString *key = url.absoluteString;
    id cached = ApolloChatMediaCache()[key];
    if (cached) { if (completion) completion(cached); return; }
    NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:url
                                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id media = nil;
        if (data.length) {
            Class fl = ApolloFLAnimatedImageClass();
            if (fl && ApolloDataIsGIF(data)) {
                id (*initFn)(id, SEL, NSData *, NSUInteger, BOOL) =
                    (id (*)(id, SEL, NSData *, NSUInteger, BOOL))objc_msgSend;
                media = initFn([fl alloc], @selector(initWithAnimatedGIFData:optimalFrameCacheSize:predrawingEnabled:),
                               data, (NSUInteger)0, YES);
            }
            if (!media) media = [UIImage imageWithData:data];   // png/jpg/webp, or gif fallback
        }
        // The expensive decode above runs on NSURLSession's background queue, but the cache WRITE is
        // hopped onto the main queue: ApolloChatMediaCache is a plain NSMutableDictionary read (and
        // written for emoji stickers) from cellForItem on the main thread, and several image loads can
        // complete concurrently on different background queues. Mutating it off-main races those reads
        // and can corrupt the dictionary / crash during a rehash, so every cache mutation happens on
        // the one (main) thread. (Reported by @nickclyde in review.)
        dispatch_async(dispatch_get_main_queue(), ^{
            if (media) ApolloChatMediaCache()[key] = media;
            if (completion) completion(media);
        });
    }];
    [t resume];
}

#pragma mark - rendering

// Persistent URL -> bubble CGSize cache. Lets re-renders during scroll size the
// bubble deterministically (independent of async image-load timing), so a recycled
// cell never flashes a mis-sized (white-cropped) image.
static NSMutableDictionary *ApolloChatSizeByURL(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// Deferred, coalesced layout invalidation. invalidateLayout called synchronously from
// cellForItem (which runs mid-layout) is ignored by UICollectionView, so a cache-hit
// image stays text-sized (cropped) until the next scroll. Dispatching to the next
// runloop makes the size override take on first open too.
static void ApolloChatScheduleReflow(id collectionView) {
    static char kPendingReflowKey;
    if (!collectionView || objc_getAssociatedObject(collectionView, &kPendingReflowKey)) return;
    objc_setAssociatedObject(collectionView, &kPendingReflowKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id wcv = collectionView;
    dispatch_async(dispatch_get_main_queue(), ^{
        id cv = wcv; if (!cv) return;
        objc_setAssociatedObject(cv, &kPendingReflowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id layout = [cv respondsToSelector:@selector(collectionViewLayout)] ? [cv collectionViewLayout] : nil;
        if (layout) [layout invalidateLayout];
    });
}

#pragma mark - tap-to-fullscreen viewer

// Nearest hosting view controller (for presenting) via the responder chain, falling back to the
// key window's top-most presented VC.
static UIViewController *ApolloChatHostVC(UIView *view) {
    UIResponder *r = view;
    while ((r = r.nextResponder)) if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (w.isKeyWindow) { key = w; break; } }
        if (key) break;
    }
    return key.rootViewController;
}

// Lightweight full-screen viewer for a tapped chat image/gif: black backdrop, pinch + double-tap
// zoom, single-tap / swipe-down / close-button to dismiss. Animated gifs keep animating.
@interface ApolloChatImageViewerVC : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) id media;   // UIImage or FLAnimatedImage
@end
@implementation ApolloChatImageViewerVC {
    UIScrollView *_scroll;
    UIImageView *_imageView;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 4.0;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    if (@available(iOS 11.0, *)) _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scroll];

    Class fl = ApolloFLAnimatedImageClass();
    BOOL animated = fl && [self.media isKindOfClass:fl];
    Class ivClass = animated ? (ApolloFLAnimatedImageViewClass() ?: [UIImageView class]) : [UIImageView class];
    _imageView = [[ivClass alloc] initWithFrame:_scroll.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (animated) ((void (*)(id, SEL, id))objc_msgSend)(_imageView, @selector(setAnimatedImage:), self.media);
    else if ([self.media isKindOfClass:[UIImage class]]) _imageView.image = self.media;
    [_scroll addSubview:_imageView];

    UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onSingleTap:)];
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [single requireGestureRecognizerToFail:dbl];
    [self.view addGestureRecognizer:single];
    [self.view addGestureRecognizer:dbl];
    UISwipeGestureRecognizer *down = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    down.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:down];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        close.tintColor = [UIColor whiteColor];
        [close setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightRegular] forImageInState:UIControlStateNormal];
    } else {
        [close setTitle:@"Close" forState:UIControlStateNormal];
        [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    [close addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    // Give the tap target room (the glyph alone is a tiny hit area) and keep it above the scroll view.
    close.frame = CGRectMake(0, 0, 44, 44);
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
    ]];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return _imageView; }
- (void)scrollViewDidZoom:(UIScrollView *)sv {
    CGSize b = sv.bounds.size; CGRect f = _imageView.frame;
    _imageView.frame = CGRectMake(f.size.width < b.width ? (b.width - f.size.width)/2 : 0,
                                  f.size.height < b.height ? (b.height - f.size.height)/2 : 0,
                                  f.size.width, f.size.height);
}
- (void)onSingleTap:(UITapGestureRecognizer *)g {
    if (_scroll.zoomScale > _scroll.minimumZoomScale) [_scroll setZoomScale:_scroll.minimumZoomScale animated:YES];
    else [self dismissSelf];
}
- (void)onDoubleTap:(UITapGestureRecognizer *)g {
    if (_scroll.zoomScale > _scroll.minimumZoomScale) { [_scroll setZoomScale:_scroll.minimumZoomScale animated:YES]; return; }
    CGFloat scale = 2.5; CGPoint pt = [g locationInView:_imageView]; CGSize s = _scroll.bounds.size;
    [_scroll zoomToRect:CGRectMake(pt.x - (s.width/scale)/2, pt.y - (s.height/scale)/2, s.width/scale, s.height/scale) animated:YES];
}
- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

// Shared tap target (one instance, retained for the app life). The recognizer is attached to the
// bubble CONTAINER, not our overlay image view — Apollo re-orders subviews on top of our overlay
// after we render, so a gesture on the iv never receives the touch. The container reliably does.
@interface ApolloChatImageTapTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)chatBubbleTapped:(UITapGestureRecognizer *)g;
@end
@implementation ApolloChatImageTapTarget
+ (instancetype)shared {
    static ApolloChatImageTapTarget *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ApolloChatImageTapTarget new]; });
    return s;
}
// Coexist with Apollo's own bubble gestures (long-press menu, link tap) rather than fighting them.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)chatBubbleTapped:(UITapGestureRecognizer *)g {
    // Find our overlay image view within the tapped bubble — the one carrying a media handle AND
    // marked interactive (sticker overlays are non-interactive, so taps on emoji are ignored).
    id media = nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:g.view];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        id m = objc_getAssociatedObject(v, &kApolloChatIvMediaKey);
        if (m && v.userInteractionEnabled) { media = m; break; }
        [q addObjectsFromArray:v.subviews];
    }
    ChatImgLog(@"BUBBLE TAP fired media=%@", media ? @"y" : @"NIL");
    if (!media) return;
    ApolloChatImageViewerVC *viewer = [ApolloChatImageViewerVC new];
    viewer.media = media;
    viewer.modalPresentationStyle = UIModalPresentationOverFullScreen;
    viewer.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *host = ApolloChatHostVC(g.view);
    while (host.presentedViewController) host = host.presentedViewController;
    if ([host isKindOfClass:[ApolloChatImageViewerVC class]]) return;   // already open
    [host presentViewController:viewer animated:YES completion:nil];
}
@end

#pragma mark - rendering image overlay

static void ApolloChatRenderImageInCell(id vc, id cell, NSURL *url, NSIndexPath *ip, id collectionView, BOOL sticker) {
    UIView *container = ApolloChatContainerView(cell);
    if (!container) return;
    NSString *urlStr = url.absoluteString;
    NSString *ipKey = ApolloChatIndexKey(ip);

    // Tap-to-fullscreen: the recognizer lives on the bubble CONTAINER (added once), because Apollo
    // re-stacks subviews over our overlay so a gesture on the iv never gets the touch. The handler
    // walks the bubble for an interactive overlay carrying media, so emoji stickers are ignored.
    if (!objc_getAssociatedObject(container, &kApolloChatContainerTapKey)) {
        objc_setAssociatedObject(container, &kApolloChatContainerTapKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        container.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:[ApolloChatImageTapTarget shared] action:@selector(chatBubbleTapped:)];
        tap.delegate = [ApolloChatImageTapTarget shared];
        [container addGestureRecognizer:tap];
    }

    UIImageView *iv = objc_getAssociatedObject(cell, &kApolloChatImgViewKey);
    if (!iv) {
        Class ivClass = ApolloFLAnimatedImageViewClass() ?: [UIImageView class];   // animates gifs
        iv = [[ivClass alloc] initWithFrame:container.bounds];
        iv.clipsToBounds = YES;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(cell, &kApolloChatImgViewKey, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Rendered media floats on the chat background with NO bubble — matching how Reddit shows
    // images/GIFs/emoji. A real image/gif gets rounded corners + aspect-fill; an emoji/snoomoji
    // sticker is transparent + unrounded (the glyph carries its own padding). We clear BOTH our image
    // view's background AND Apollo's blue/grey message container, so a transparent PNG (folder icon)
    // or a snoomoji shows the chat background through its margins instead of sitting in a box.
    // MessageKit re-applies the bubble colour when this cell is reused for a text message.
    if (sticker) {
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.cornerRadius = 0.0;
    } else {
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.layer.cornerRadius = 15.0;   // rounds opaque photos; transparent PNGs ignore it
    }
    iv.backgroundColor = [UIColor clearColor];
    container.backgroundColor = [UIColor clearColor];
    iv.userInteractionEnabled = !sticker;   // tappable for images/gifs, not for emoji stickers
    if (iv.superview != container) [container addSubview:iv];
    [container bringSubviewToFront:iv];
    iv.frame = container.bounds;
    objc_setAssociatedObject(cell, &kApolloChatImgURLKey, urlStr, OBJC_ASSOCIATION_COPY_NONATOMIC);

    id cachedMedia = ApolloChatMediaCache()[urlStr];
    NSValue *knownSize = ApolloChatSizeByURL()[urlStr];
    // Unicode emoji (our synthetic x-apollo-emoji:// scheme) render at normal text-emoji size with
    // built-in (rasterized) padding; Reddit snoomoji art renders larger and is inset within the
    // bubble so the tightly-cropped art sits centered with breathing room instead of edge-cramped.
    BOOL isUnicodeEmoji = [url.scheme isEqualToString:@"x-apollo-emoji"];
    CGFloat stickerH = isUnicodeEmoji ? kApolloChatUnicodeEmojiHeight : kApolloChatSnoomojiHeight;
    CGFloat stickerInset = (sticker && !isUnicodeEmoji) ? kApolloChatSnoomojiInset : 0.0;
    objc_setAssociatedObject(iv, &kApolloChatStickerInsetKey, @(stickerInset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    iv.frame = CGRectInset(container.bounds, stickerInset, stickerInset);   // snoomoji: centered with margin

    // Commit a size to BOTH the cell (drives applyLayoutAttributes' container width)
    // and the VC map (drives sizeForItemAtIndexPath's height) so they never disagree.
    void (^applySize)(id, NSValue *) = ^(id theCell, NSValue *mv) {
        objc_setAssociatedObject(theCell, &kApolloChatImgMediaSizeKey, mv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Keyed on the collection view so the flow-layout hook (queried on every
        // scroll) and sizeForItem both see the same per-index size.
        if (collectionView) {
            if (mv) ApolloChatSizeMap(collectionView)[ipKey] = mv;
            else    [ApolloChatSizeMap(collectionView) removeObjectForKey:ipKey];
        }
    };

    if (knownSize) {
        // We've measured this media before: size the bubble deterministically right now.
        // Even if the gif isn't decoded yet, the placeholder fill (not white) shows.
        applySize(cell, knownSize);
        ApolloChatMessageLabel(cell).hidden = YES;
        ApolloChatScheduleReflow(collectionView);   // apply the size on first open (not just after a scroll)
    } else {
        // First time we see this media: stay a normal text bubble until it's measured,
        // so we never show a big empty bubble.
        applySize(cell, nil);
        ApolloChatMessageLabel(cell).hidden = NO;
    }

    if (cachedMedia) {
        ApolloChatSetMedia(iv, cachedMedia);
        ApolloChatMessageLabel(cell).hidden = YES;
        if (!knownSize) {
            NSValue *mv = [NSValue valueWithCGSize:(sticker ? ApolloChatStickerSize((UIImage *)cachedMedia, stickerH) : ApolloChatMediaSize((UIImage *)cachedMedia))];
            ApolloChatSizeByURL()[urlStr] = mv;
            applySize(cell, mv);
            ApolloChatScheduleReflow(collectionView);
        }
        return;
    }

    // Load asynchronously (gif-aware); commit size + media together when it arrives.
    __weak UIImageView *weakIV = iv;
    __weak id weakCell = cell, weakCV = collectionView;
    ApolloChatLoadMedia(url, ^(id media) {
        UIImageView *sIV = weakIV; id sCell = weakCell;
        if (!media || !sIV || !sCell) return;
        if (![objc_getAssociatedObject(sCell, &kApolloChatImgURLKey) isEqualToString:urlStr]) return; // recycled
        NSValue *mv = [NSValue valueWithCGSize:(sticker ? ApolloChatStickerSize((UIImage *)media, stickerH) : ApolloChatMediaSize((UIImage *)media))];
        ApolloChatSizeByURL()[urlStr] = mv;
        objc_setAssociatedObject(sCell, &kApolloChatImgMediaSizeKey, mv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (weakCV) ApolloChatSizeMap(weakCV)[ipKey] = mv;
        ApolloChatSetMedia(sIV, media);
        UIView *c = ApolloChatContainerView(sCell);
        if (c) sIV.frame = c.bounds;
        ApolloChatMessageLabel(sCell).hidden = YES;
        ApolloChatScheduleReflow(weakCV);
    });
}

static void ApolloChatClearImageInCell(id cell) {
    UIImageView *iv = objc_getAssociatedObject(cell, &kApolloChatImgViewKey);
    if (iv) { ApolloChatClearMedia(iv); [iv removeFromSuperview]; }
    objc_setAssociatedObject(cell, &kApolloChatImgViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloChatImgURLKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloChatImgMediaSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILabel *lab = ApolloChatMessageLabel(cell);
    if (lab) lab.hidden = NO;
}

static void ApolloChatApplyAvatarToCell(id cell);                    // defined below
static void ApolloChatLoadSnoomoji(id collectionView);               // defined below (fetches the snoomoji table)
static NSURL *ApolloChatSnoomojiStickerURL(UILabel *label);          // defined below (single-snoomoji -> URL)
static NSString *ApolloChatPureEmojiBody(UILabel *label);            // defined below (pure-emoji body -> string)
static BOOL ApolloChatRunIsEmoji(NSString *s);                       // defined below

static void ApolloChatProcessCell(id vc, id collectionView, id cell, NSIndexPath *indexPath) {
    @try {
        UILabel *label = ApolloChatMessageLabel(cell);
        NSURL *imgURL = nil;
        BOOL sticker = NO;
        // Master toggle: when OFF we render nothing (fall through to clear any overlay + show the
        // stock text/link), so chat reverts to stock Apollo. Avatars below stay ungated (own toggle).
        if (sEnableChatMedia) {
            // Kick the snoomoji table load (dispatch_once) so a single-snoomoji bubble can resolve to
            // a sticker. On the very first open the table isn't ready yet; ApolloChatLoadSnoomoji's
            // completion re-runs this pipeline for the visible cells once it lands.
            ApolloChatLoadSnoomoji(collectionView);

            imgURL = label ? ApolloChatImageURLFromAttributed(label.attributedText) : nil;
            if (!imgURL && label) {
                // Apollo "jumbo-blanks" a message that is just emoji (a Reddit snoomoji renders as the
                // bare NAME, a unicode emoji renders invisibly), and its TextKit-backed MessageLabel
                // won't reliably draw a glyph/attachment we inject. So render any pure-emoji bubble as a
                // sticker overlay — the same proven path as inline gifs/images.
                NSURL *s = ApolloChatSnoomojiStickerURL(label);          // :snoo_hearteyes: -> emoji CDN URL
                if (!s) {
                    NSString *e = ApolloChatPureEmojiBody(label);        // 👍 / 🤜🤛 -> rasterized sticker
                    if (e) s = ApolloChatEmojiStickerURL(e);
                }
                if (s) { imgURL = s; sticker = YES; }
            }
            // An ImgChest post URL (imgchest.com/p/<id>) isn't a direct image — resolve it to the CDN
            // image via the shared resolver, then render that. Our own sent images use this short link;
            // inbound ImgChest links resolve the same way. Until resolved, leave it as text/link.
            if (imgURL && !sticker && ApolloImageChestIsPostURL(imgURL)) {
                NSURL *direct = ApolloChatDirectURLFromImageChest(ApolloImageChestCachedResolution(imgURL));
                if (direct) {
                    imgURL = direct;
                } else {
                    __weak id wcv = collectionView;
                    ApolloImageChestResolveURL(imgURL, ^(__unused NSDictionary *r) {
                        if (wcv) ApolloChatScheduleReflow(wcv);
                    });
                    imgURL = nil;
                }
            }
        }
        if (imgURL) {
            ChatImgLog(@"detected %@ %@ -> %@", sticker ? @"snoomoji" : @"image", ApolloChatIndexKey(indexPath), imgURL.absoluteString);
            ApolloChatRenderImageInCell(vc, cell, imgURL, indexPath, collectionView, sticker);
        } else {
            if (cell && objc_getAssociatedObject(cell, &kApolloChatImgViewKey)) ApolloChatClearImageInCell(cell);
            // Keep the index-path size map in sync with reality: this row is NOT an image,
            // so drop any image size still cached for its index path (an earlier image that
            // occupied this index path, or one shifted here when a newer message inserted).
            // Otherwise sizeForItem + the flow-layout override keep sizing this text bubble
            // to the stale image height (the giant ":orly:" bubble). Reflow to re-lay-out.
            NSMutableDictionary *map = objc_getAssociatedObject(collectionView, &kApolloChatImgSizeMapKey);
            NSString *ipKey = ApolloChatIndexKey(indexPath);
            if (map[ipKey]) { [map removeObjectForKey:ipKey]; ApolloChatScheduleReflow(collectionView); }
            // Avatars only on text bubbles (image/sticker bubbles hide the header label).
            ApolloChatApplyAvatarToCell(cell);
        }
    } @catch (__unused id e) {}
}

static CGSize ApolloChatSizeOverride(id vc, id collectionView, CGSize orig, NSIndexPath *indexPath) {
    @try {
        NSValue *mv = ApolloChatSizeMap(collectionView)[ApolloChatIndexKey(indexPath)];
        if ([mv isKindOfClass:[NSValue class]]) {
            CGSize media = mv.CGSizeValue;
            return CGSizeMake(orig.width, media.height + 22.0);
        }
    } @catch (__unused id e) {}
    return orig;
}

#pragma mark - avatars (feature 3)

// Oval-clipped, aspect-fill avatar render (transparent corners). Nil -> neutral fill.
static UIImage *ApolloChatCircularAvatar(UIImage *src, CGFloat d) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = [UIScreen mainScreen].scale; fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, d, d);
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        if (src) {
            CGFloat a = src.size.width > 0 ? src.size.height / src.size.width : 1.0;
            CGFloat w = d, h = d;
            if (a > 1.0) { w = d; h = d * a; } else if (a > 0.0) { w = d / a; h = d; }
            [src drawInRect:CGRectMake((d - w) / 2.0, (d - h) / 2.0, w, h)];
        } else {
            [[UIColor secondarySystemFillColor] setFill]; UIRectFill(rect);
        }
    }];
}

// Author username = first whitespace token of the bubble header ("iChopPryde  1h\n…").
static NSString *ApolloChatAuthorFromLabel(UILabel *label) {
    NSString *t = label.text;
    if (t.length == 0) return nil;
    if ([t characterAtIndex:0] == 0xFFFC) return nil;   // already stamped this configure
    NSRange nl = [t rangeOfString:@"\n"];
    NSString *firstLine = nl.location != NSNotFound ? [t substringToIndex:nl.location] : t;
    for (NSString *tok in [firstLine componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (tok.length == 0) continue;
        return [tok hasPrefix:@"u/"] ? [tok substringFromIndex:2] : tok;
    }
    return nil;
}

static const CGFloat kApolloChatAvatarDiameter = 18.0;

// Build the "[avatar] " prefix attributed string for a given avatar image.
static NSAttributedString *ApolloChatAvatarPrefix(UIImage *avatar) {
    NSTextAttachment *att = [NSTextAttachment new];
    att.image = ApolloChatCircularAvatar(avatar, kApolloChatAvatarDiameter);
    att.bounds = CGRectMake(0, -4, kApolloChatAvatarDiameter, kApolloChatAvatarDiameter);
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] init];
    [m appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    return m;
}

// Stamp the sender's avatar into the bubble header (next to the username).
static void ApolloChatApplyAvatarToCell(id cell) {
    if (!sShowUserAvatars) return;
    UILabel *label = ApolloChatMessageLabel(cell);
    if (!label || label.hidden || label.attributedText.length == 0) return;   // image cells hide the label
    NSString *author = ApolloChatAuthorFromLabel(label);
    if (author.length == 0) return;
    objc_setAssociatedObject(cell, &kApolloChatAvatarUserKey, author, OBJC_ASSOCIATION_COPY_NONATOMIC);

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *info = [cache cachedInfoForUsername:author];
    NSURL *url = info ? (info.iconURL ?: info.snoovatarURL) : nil;
    UIImage *cachedImg = url ? [cache cachedImageForURL:url] : nil;

    // Prepend the avatar (real if cached, neutral placeholder otherwise).
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] init];
    [m appendAttributedString:ApolloChatAvatarPrefix(cachedImg)];
    [m appendAttributedString:label.attributedText];
    label.attributedText = m;
    if (cachedImg) return;

    // Resolve asynchronously, then swap the placeholder attachment's image in place.
    __weak id wcell = cell;
    void (^update)(UIImage *) = ^(UIImage *img) {
        id scell = wcell; if (!img || !scell) return;
        if (![objc_getAssociatedObject(scell, &kApolloChatAvatarUserKey) isEqualToString:author]) return;
        UILabel *lab = ApolloChatMessageLabel(scell);
        if (!lab || lab.hidden || lab.attributedText.length == 0) return;
        if ([lab.text characterAtIndex:0] != 0xFFFC) return;   // header no longer ours
        NSTextAttachment *att = [lab.attributedText attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:NULL];
        if (![att isKindOfClass:[NSTextAttachment class]]) return;
        att.image = ApolloChatCircularAvatar(img, kApolloChatAvatarDiameter);
        att.bounds = CGRectMake(0, -4, kApolloChatAvatarDiameter, kApolloChatAvatarDiameter);
        lab.attributedText = [lab.attributedText copy];   // re-set to force a redraw
    };
    if (info && url) {
        [cache requestImageForURL:url completion:update];
    } else {
        [cache requestInfoForUsername:author completion:^(ApolloUserProfileInfo *info2) {
            NSURL *u = info2.iconURL ?: info2.snoovatarURL;
            if (u) [cache requestImageForURL:u completion:update];
        }];
    }
}

#pragma mark - inline snoomoji (render :name: emoji like the website chat does)

// Apollo resolves :name: emoji in comments/posts from each item's media_metadata, but a bridged
// chat RDKMessage carries no media_metadata — just the markdown body with :name: tokens. So we
// resolve names ourselves: load Reddit's platform "snoomoji" set (name -> image URL) once,
// preload the small images, then swap :name: tokens in message bubbles for the emoji image (the
// same idea as the inline gif/image rendering, keyed by name instead of URL).
static NSMutableDictionary<NSString *, NSURL *> *ApolloChatSnoomojiMap(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// The message body, with Apollo's leading "sender  timeago" header line (always the FIRST line of
// these cells) stripped. A pure-emoji or single-snoomoji bubble's body is exactly the emoji.
static NSString *ApolloChatMessageBody(UILabel *label) {
    if (!label || label.attributedText.length == 0) return nil;
    NSString *full = label.attributedText.string;
    if (full.length == 0) return nil;
    NSRange nl = [full rangeOfString:@"\n"];   // FIRST newline = end of the header line
    NSString *body = (nl.location == NSNotFound) ? full : [full substringFromIndex:nl.location + 1];
    return [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// If this bubble is essentially a single Reddit snoomoji, return its image URL (else nil). Apollo
// draws such a message as the bare emoji NAME (e.g. "snoo_hearteyes"; some, like ":orly:", keep
// their colons). The whole body must be one token, AND — to avoid hijacking a plain one-word
// message that merely equals a snoomoji name (e.g. someone literally typing "doge" or "cake") and
// hiding their text — a BARE (no-colon) name is only accepted when it's unambiguously an emoji
// token: it carries the explicit :name: syntax, contains an underscore/digit (snoo_hearteyes…), or
// is a universal Reddit vote reaction. Plain dictionary words require the :name: form.
static NSURL *ApolloChatSnoomojiStickerURL(UILabel *label) {
    NSMutableDictionary *map = ApolloChatSnoomojiMap();
    if (map.count == 0) return nil;
    NSString *body = ApolloChatMessageBody(label);
    if (body.length == 0) return nil;
    if ([body rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
        return nil;   // the whole body must be a single token
    BOOL colonWrapped = body.length >= 3 && [body hasPrefix:@":"] && [body hasSuffix:@":"];
    NSString *token = colonWrapped ? [body substringWithRange:NSMakeRange(1, body.length - 2)] : body;
    if (token.length == 0) return nil;
    NSString *key = token.lowercaseString;
    if (!map[key]) return nil;
    if (!colonWrapped) {
        // bare name: require it to look like an emoji token, not a plain word
        BOOL emojiShaped = [token rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"_0123456789"]].location != NSNotFound;
        static NSSet *voteReactions; static dispatch_once_t once;
        dispatch_once(&once, ^{ voteReactions = [NSSet setWithArray:@[@"upvote", @"downvote"]]; });
        if (!emojiShaped && ![voteReactions containsObject:key]) return nil;
    }
    return map[key];
}

// If the whole message body is pure emoji (👍, 🤜🤛, etc.), return that emoji string (else nil).
// Mixed text+emoji ("ok 👍") returns nil — Apollo renders those inline fine; only a lone-emoji
// bubble gets jumbo-blanked, and that's the case we turn into a rasterized sticker.
static NSString *ApolloChatPureEmojiBody(UILabel *label) {
    NSString *body = ApolloChatMessageBody(label);
    if (body.length == 0) return nil;
    return ApolloChatRunIsEmoji(body) ? body : nil;
}
// Fetch the platform snoomoji name->URL table once. We render single-snoomoji bubbles as image
// stickers (the overlay path), so we only need the URLs here — the bytes are fetched + decoded
// (and gif-animated) on demand by ApolloChatLoadMedia, exactly like inbound chat images.
static void ApolloChatLoadSnoomoji(id collectionView) {
    // Called only from ApolloChatProcessCell (cellForItem / the main-queue re-run) — i.e. always on the
    // main thread — so these guards need no lock. We deliberately do NOT use dispatch_once: a single
    // failed or empty first fetch (launched offline, or before the Reddit bearer token is captured)
    // must not permanently disable snoomoji for the session. `sLoaded` latches only once the map is
    // actually populated; `sInFlight` coalesces duplicate fetches but is cleared on a transient
    // failure so the next chat open retries. (Reported by @nickclyde in review.)
    static BOOL sLoaded = NO;     // YES only after the map has been populated with entries
    static BOOL sInFlight = NO;   // a fetch is currently running (avoid duplicate concurrent fetches)
    if (sLoaded || sInFlight) return;
    sInFlight = YES;
    __weak id wcv = collectionView;
    NSString *bearer = sLatestRedditBearerToken;
    NSString *sub = @"nintendo";   // any emoji-enabled sub returns the platform "snoomojis" section
    NSString *urlStr = bearer.length
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/api/v1/%@/emojis/all?raw_json=1", sub]
        : [NSString stringWithFormat:@"https://www.reddit.com/api/v1/%@/emojis/all.json?raw_json=1", sub];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    if (bearer.length) [req setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // Parse off-main into a LOCAL dictionary (no shared state touched on the background queue)...
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *snoo = [json isKindOfClass:[NSDictionary class]] ? json[@"snoomojis"] : nil;
        NSMutableDictionary<NSString *, NSURL *> *parsed = [NSMutableDictionary dictionary];
        if ([snoo isKindOfClass:[NSDictionary class]]) {
            for (NSString *name in snoo) {
                NSDictionary *e = snoo[name];
                NSString *u = [e isKindOfClass:[NSDictionary class]] ? e[@"url"] : nil;
                NSURL *url = [u isKindOfClass:[NSString class]] ? [NSURL URLWithString:u] : nil;
                if (name.length && url) parsed[name.lowercaseString] = url;
            }
        }
        // ...then merge into the shared map + flip the guards on the MAIN thread, so the snoomoji map
        // is only ever mutated on the same thread ApolloChatSnoomojiStickerURL reads it on.
        dispatch_async(dispatch_get_main_queue(), ^{
            sInFlight = NO;
            ChatImgLog(@"snoomoji fetch: %lu entries (sample orly=%@)",
                       (unsigned long)parsed.count, parsed[@"orly"] ? @"y" : @"-");
            if (parsed.count == 0) return;   // transient failure: leave sLoaded NO so the next open retries
            [ApolloChatSnoomojiMap() addEntriesFromDictionary:parsed];
            sLoaded = YES;
            // Re-run the cell pipeline for what's already on screen: any single-snoomoji bubble
            // that rendered as bare text before the table arrived now resolves to a sticker.
            id cv = wcv;
            if (!cv || ![cv respondsToSelector:@selector(visibleCells)]) return;
            id dvc = [cv respondsToSelector:@selector(delegate)] ? [(UICollectionView *)cv delegate] : nil;
            for (id cell in [(UICollectionView *)cv visibleCells]) {
                NSIndexPath *ip = [(UICollectionView *)cv indexPathForCell:cell];
                if (dvc && ip) ApolloChatProcessCell(dvc, cv, cell, ip);
            }
        });
    }] resume];
}

// Is the whole string a pure emoji (no regular letters/digits)? Used to spot a single-emoji
// message body that Apollo blanked.
static BOOL ApolloChatRunIsEmoji(NSString *s) {
    if (s.length == 0) return NO;
    __block BOOL emoji = NO, text = NO;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r1, NSRange r2, BOOL *stop) {
        if (sub.length == 0) return;
        unichar c = [sub characterAtIndex:0];
        if (c >= 0xD800 && c <= 0xDBFF) emoji = YES;                         // astral plane (most emoji)
        else if (c >= 0x2190 && c <= 0x2BFF) emoji = YES;                    // BMP arrows/symbols/dingbats
        else if (c == 0xFE0F || c == 0x200D || c == 0x20E3 || c == 0x2122 || c == 0xA9 || c == 0xAE) { /* modifiers */ }
        else if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) text = YES;
    }];
    return emoji && !text;
}

#pragma mark - hooks

// Resize the bubble for image rows: override the layout attributes' messageContainerSize
// so MessageKit sizes + positions (and side-aligns) the bubble for us.
%hook _TtC6Apollo15TextMessageCell
// Reset our per-cell state on reuse so a recycled image cell doesn't carry stale
// media sizing onto a text bubble (which made text wrap at the narrow image width).
- (void)prepareForReuse {
    %orig;
    UIImageView *iv = objc_getAssociatedObject(self, &kApolloChatImgViewKey);
    if (iv) { ApolloChatClearMedia(iv); [iv removeFromSuperview]; }
    objc_setAssociatedObject(self, &kApolloChatImgViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kApolloChatImgURLKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, &kApolloChatImgMediaSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kApolloChatAvatarUserKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UILabel *lab = ApolloChatMessageLabel(self);
    if (lab) lab.hidden = NO;
}
- (void)applyLayoutAttributes:(id)attributes {
    NSValue *mv = objc_getAssociatedObject(self, &kApolloChatImgMediaSizeKey);
    if (mv && attributes) {
        ApolloChatSetCGSizeIvar(attributes, "messageContainerSize", mv.CGSizeValue);
    }
    %orig;
    if (mv) {
        UIImageView *iv = objc_getAssociatedObject(self, &kApolloChatImgViewKey);
        UIView *c = ApolloChatContainerView(self);
        if (iv && c && iv.superview == c) {
            CGFloat inset = [objc_getAssociatedObject(iv, &kApolloChatStickerInsetKey) doubleValue];
            iv.frame = CGRectInset(c.bounds, inset, inset);   // snoomoji art sits centered with margin
        }
    }
}
%end

// The cell's applyLayoutAttributes only re-fires on (re)configuration, so on a plain
// scroll the cached attributes' (text-sized) messageContainerSize would be reused,
// clipping the big image. The flow layout's attribute query runs on every scroll —
// override messageContainerSize here (keyed by index path via the collection-view map)
// so an image bubble is sized correctly whether freshly built or scrolled back in.
%hook _TtC6Apollo32MessagesCollectionViewFlowLayout
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSArray *attrs = %orig;
    @try {
        NSMutableDictionary *map = objc_getAssociatedObject([(UICollectionViewLayout *)self collectionView], &kApolloChatImgSizeMapKey);
        for (UICollectionViewLayoutAttributes *la in attrs) {
            if (![la isKindOfClass:[UICollectionViewLayoutAttributes class]]) continue;
            NSString *key = ApolloChatIndexKey(la.indexPath);
            NSValue *mv = map[key];
            if (mv) {
                ApolloChatSetCGSizeIvar(la, "messageContainerSize", mv.CGSizeValue);
            } else if (sShowUserAvatars) {
                // Widen text bubbles so the avatar prefix doesn't push the timestamp onto
                // a second header line where it hides the message body.
                CGSize cur = ApolloChatGetCGSizeIvar(la, "messageContainerSize");
                if (cur.width > 0)
                    ApolloChatSetCGSizeIvar(la, "messageContainerSize",
                        CGSizeMake(cur.width + kApolloChatAvatarDiameter + 6.0, cur.height));
            }
        }
    } @catch (__unused id e) {}
    return attrs;
}
- (id)layoutAttributesForItemAtIndexPath:(id)indexPath {
    id la = %orig;
    @try {
        NSMutableDictionary *map = objc_getAssociatedObject([(UICollectionViewLayout *)self collectionView], &kApolloChatImgSizeMapKey);
        if ([la isKindOfClass:[UICollectionViewLayoutAttributes class]]) {
            NSValue *mv = map[ApolloChatIndexKey(indexPath)];
            if (mv) {
                ApolloChatSetCGSizeIvar(la, "messageContainerSize", mv.CGSizeValue);
            } else if (sShowUserAvatars) {
                CGSize cur = ApolloChatGetCGSizeIvar(la, "messageContainerSize");
                if (cur.width > 0)
                    ApolloChatSetCGSizeIvar(la, "messageContainerSize",
                        CGSizeMake(cur.width + kApolloChatAvatarDiameter + 6.0, cur.height));
            }
        }
    } @catch (__unused id e) {}
    return la;
}
%end

%hook _TtC6Apollo28PrivateMessageViewController
- (id)collectionView:(id)collectionView cellForItemAtIndexPath:(id)indexPath {
    id cell = %orig;
    ApolloChatProcessCell(self, collectionView, cell, indexPath);
    return cell;
}
- (CGSize)collectionView:(id)collectionView layout:(id)layout sizeForItemAtIndexPath:(id)indexPath {
    return ApolloChatSizeOverride(self, collectionView, %orig, indexPath);
}
%end

%hook _TtC6Apollo22MessagesViewController
- (id)collectionView:(id)collectionView cellForItemAtIndexPath:(id)indexPath {
    id cell = %orig;
    ApolloChatProcessCell(self, collectionView, cell, indexPath);
    return cell;
}
- (CGSize)collectionView:(id)collectionView layout:(id)layout sizeForItemAtIndexPath:(id)indexPath {
    return ApolloChatSizeOverride(self, collectionView, %orig, indexPath);
}
%end

%ctor {
    ApolloLog(@"[ChatImg] module loaded");
}
