// ApolloFeedGalleryCarousel.xm
//
// Replaces Apollo's fixed Reddit-gallery mosaic in LARGE feed cards with a
// horizontally paging carousel. The native RDKGallery remains the model and
// Apollo's MediaPageViewController remains the fullscreen viewer; this module
// only replaces the in-feed presentation.
//
// Safety / scope:
//   * Reddit-native image galleries only. ImgurAlbum is a Swift value-type ivar
//     and mixed image/video galleries retain Apollo's native mosaic.
//   * Comments media headers retain Apollo's native presentation.
//   * NSFW/spoiler galleries ARE supported. No image is requested or decoded
//     until the user reveals the cover. Reveal state rides on the RDKLink
//     model, so it persists exactly as long as Apollo caches that link (which
//     can span screens), and resets when the model is refetched.
//   * Preview images are lazy-loaded at current +/- 1 through Apollo's bundled
//     PINRemoteImage pipeline. Decoded images outside a small retention window
//     are released, and every image is released when the card leaves a window.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"

struct ApolloFeedGallerySizeRange { CGSize min; CGSize max; };

@interface ASLayoutSpec : NSObject
@end

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (UIView *)view;
- (BOOL)isNodeLoaded;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface RDKGallery : NSObject
@property (retain, nonatomic) NSArray *items;
@end

@interface RDKGalleryItemImage : NSObject
@property (nonatomic) double width;
@property (nonatomic) double height;
@property (retain, nonatomic) NSURL *url;
@property (retain, nonatomic) NSURL *mp4URL;
@end

@interface RDKGalleryItem : NSObject
@property (copy, nonatomic) NSArray *previewImages;
@property (copy, nonatomic) RDKGalleryItemImage *image;
@end

// Apollo already uses PINRemoteImage throughout the feed. Use its UIImageView
// category here as well so the carousel participates in the app's warm memory
// and disk caches instead of starting a second NSURLSession/cache pipeline.
@interface UIImageView (ApolloFeedGalleryPINRemoteImage)
- (void)pin_setImageFromURL:(NSURL *)URL;
- (void)pin_cancelImageDownload;
@end

// Required by the %hook below (Logos types `self` with this class).
@interface _TtC6Apollo23MediaPageViewController : UIPageViewController
@end

// Apollo's native album mosaic is 16:9 (confirmed in Hopper's
// AlbumThumbnailsNode.layoutSpecThatFits helper: height = width * 0.5625).
// The carousel sizes each card to the gallery's median image aspect instead,
// clamped between that 16:9 floor and a 5:4 portrait ceiling: a full-bleed
// pager reads as "the image", so center-cropping a portrait photo into a hard
// 16:9 box looked like a bug, while an unclamped 1:3 comic would swallow the
// feed. AspectFill within the clamp keeps residual crops modest.
static const CGFloat kApolloFeedGalleryRatio = 9.0 / 16.0;
static const CGFloat kApolloFeedGalleryMaxRatio = 5.0 / 4.0;

static CGFloat ApolloFeedGalleryRatioForItems(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSNumber *> *aspects = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        double aspect = [item[@"aspect"] doubleValue];
        if (aspect > 0.0) [aspects addObject:@(aspect)];
    }
    if (aspects.count == 0) return kApolloFeedGalleryRatio;
    [aspects sortUsingSelector:@selector(compare:)];
    CGFloat median = aspects[aspects.count / 2].doubleValue;
    return MAX(kApolloFeedGalleryRatio, MIN(kApolloFeedGalleryMaxRatio, median));
}
// Resolved once in %ctor. If a future Apollo build ships without
// PINRemoteImage's UIImageView category, the whole feature stays native
// instead of crashing on an unrecognized selector (worst case in dealloc).
static BOOL sApolloFeedGalleryPINAvailable = NO;

static char kApolloFeedGalleryHostNodeKey;
static char kApolloFeedGalleryViewKey;
static char kApolloFeedGalleryOwnerBoxKey;
static char kApolloFeedGalleryRevealKey;
static char kApolloFeedGalleryPendingViewerIndexKey;
static char kApolloFeedGalleryItemsCacheKey;
static char kApolloFeedGalleryApplyStateKey;
static char kApolloFeedGalleryTrackedNodeKey;

@interface ApolloFeedGalleryOwnerBox : NSObject
@property (nonatomic, weak) id owner;
@end
@implementation ApolloFeedGalleryOwnerBox
@end

@interface ApolloFeedGalleryPendingSelection : NSObject
@property (nonatomic) NSInteger index;
@end
@implementation ApolloFeedGalleryPendingSelection
@end

@interface ApolloFeedGalleryApplyState : NSObject
@property (nonatomic, weak) id albumNode;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL nsfw;
@property (nonatomic) BOOL spoiler;
@end
@implementation ApolloFeedGalleryApplyState
@end

static id ApolloFeedGalleryObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Swift.Bool occupies one byte at the runtime ivar offset. This is only used
// for the two documented Bool fields on AlbumThumbnailsNode/RichMediaNode; no
// Swift value-type/object bridging is attempted here. The type-encoding guard
// makes an Apollo-update field retype degrade to "carousel stays native"
// instead of silently reading a byte of an adjacent field.
static BOOL ApolloFeedGalleryBoolIvar(id object, const char *name) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (encoding && *encoding && strcmp(encoding, "B") != 0 && strcmp(encoding, "c") != 0) {
        return NO;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    const unsigned char *base = (const unsigned char *)(__bridge const void *)object;
    return base[offset] != 0;
}

// The 9-byte Swift Optional<Int> write (payload + .some discriminator) is only
// safe while no other ivar starts inside those 9 bytes. Verified at runtime so
// an Apollo layout change degrades to "viewer opens at its native index"
// instead of corrupting the neighbouring field (which is a retained pointer).
static BOOL ApolloFeedGalleryCanWriteOptionalIndexIvar(Class cls, Ivar target) {
    ptrdiff_t start = ivar_getOffset(target);
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    BOOL safe = YES;
    for (unsigned int index = 0; index < count && safe; index++) {
        if (ivars[index] == target) continue;
        ptrdiff_t offset = ivar_getOffset(ivars[index]);
        if (offset > start && offset < start + (ptrdiff_t)(sizeof(NSInteger) + 1)) safe = NO;
    }
    free(ivars);
    return safe;
}

static id ApolloFeedGalleryRichMediaNode(id albumNode) {
    ApolloFeedGalleryOwnerBox *box = objc_getAssociatedObject(albumNode, &kApolloFeedGalleryOwnerBoxKey);
    if (box.owner) return box.owner;

    id node = albumNode;
    for (NSInteger depth = 0; node && depth < 4; depth++) {
        node = [node respondsToSelector:@selector(supernode)] ? [node supernode] : nil;
        if ([NSStringFromClass([node class]) isEqualToString:@"_TtC6Apollo13RichMediaNode"]) return node;
    }
    return nil;
}

static RDKLink *ApolloFeedGalleryLink(id albumNode) {
    return ApolloFeedGalleryObjectIvar(ApolloFeedGalleryRichMediaNode(albumNode), "link");
}

// Reddit preview arrays are normally ascending by width. Select the smallest
// preview that is still large enough for a 3x full-width phone card; otherwise
// take the largest preview, then fall back to the source image.
static NSURL *ApolloFeedGalleryPreviewURL(RDKGalleryItem *item) {
    RDKGalleryItemImage *bestAboveTarget = nil;
    RDKGalleryItemImage *largest = nil;
    for (id candidate in item.previewImages) {
        if (![candidate respondsToSelector:@selector(url)]) continue;
        RDKGalleryItemImage *image = candidate;
        if (![image.url isKindOfClass:[NSURL class]]) continue;
        if (!largest || image.width > largest.width) largest = image;
        if (image.width >= 900.0 && (!bestAboveTarget || image.width < bestAboveTarget.width)) {
            bestAboveTarget = image;
        }
    }
    return bestAboveTarget.url ?: largest.url ?: item.image.url;
}

// Returns nil for unsupported/mixed galleries so Apollo's mosaic remains the
// fail-safe renderer. The returned dictionaries contain only immutable values
// safe to carry from Texture's background layout thread onto the main thread.
static NSArray<NSDictionary *> *ApolloFeedGalleryItems(id albumNode) {
    RDKGallery *gallery = ApolloFeedGalleryObjectIvar(albumNode, "redditGallery");
    if (![gallery isKindOfClass:NSClassFromString(@"RDKGallery")]) return nil;
    if (![gallery.items isKindOfClass:[NSArray class]] || gallery.items.count < 2) return nil;

    // RDKGallery is immutable for a post. Texture may measure the same node
    // many times while scrolling; cache both supported and unsupported results
    // on the model instead of walking every preview array on every pass.
    id cached = objc_getAssociatedObject(gallery, &kApolloFeedGalleryItemsCacheKey);
    if (cached) return cached == NSNull.null ? nil : cached;

    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:gallery.items.count];
    for (id rawItem in gallery.items) {
        if (![rawItem respondsToSelector:@selector(image)]) {
            objc_setAssociatedObject(gallery, &kApolloFeedGalleryItemsCacheKey, NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
        RDKGalleryItem *item = rawItem;
        RDKGalleryItemImage *source = item.image;
        // Mixed/video galleries stay native for this first scope. A static
        // poster is not an honest representation of a playable gallery page.
        if (![source isKindOfClass:NSClassFromString(@"RDKGalleryItemImage")] || source.mp4URL) {
            objc_setAssociatedObject(gallery, &kApolloFeedGalleryItemsCacheKey, NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
        NSURL *previewURL = ApolloFeedGalleryPreviewURL(item);
        if (![previewURL isKindOfClass:[NSURL class]]) {
            objc_setAssociatedObject(gallery, &kApolloFeedGalleryItemsCacheKey, NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return nil;
        }
        double aspect = (source.width > 0.0 && source.height > 0.0)
            ? source.height / source.width : 0.0;
        [result addObject:@{ @"previewURL": previewURL, @"aspect": @(aspect) }];
    }
    NSArray *items = result.count >= 2 ? [result copy] : nil;
    objc_setAssociatedObject(gallery, &kApolloFeedGalleryItemsCacheKey, items ?: NSNull.null,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return items;
}

#pragma mark - Gesture-cooperative paging scroll view

static UINavigationController *ApolloFeedGalleryAncestorNavigationController(UIView *view) {
    for (UIResponder *responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            UIViewController *viewController = (UIViewController *)responder;
            if (viewController.navigationController) return viewController.navigationController;
            return [viewController isKindOfClass:[UINavigationController class]]
                ? (UINavigationController *)viewController : nil;
        }
    }
    return nil;
}

// A drag that ends pulled at least this far past the first/last page commits
// to navigation on release. UIScrollView rubber-banding roughly halves finger
// travel in the overscroll region, so 16pt of offset is ~32pt of finger — a
// deliberate pull, but far less than a page turn.
static const CGFloat kApolloFeedGalleryReleaseHandOffOverscroll = 16.0;

// The begin-time hand-off only acts on an unambiguous velocity: below this
// floor the hysteresis reading is jitter, and a wrong-sign blip would hand
// the touch away and navigate — the one failure mode worse than a bounce.
// Marginal drags simply fall through to the release-past-edge path, which
// decides from release position and needs no velocity at all.
static const CGFloat kApolloFeedGalleryHandOffMinimumVelocity = 150.0;

// ApolloNavigationController keeps the pages popped by swipe-back in a Swift
// [UIViewController] ivar named poppedViewControllers; its goForward command
// and right-side navigation pan re-push from it (RE: the class's ivar list and
// method list). A Swift array ivar is a single word holding the storage
// object, which on Darwin is an NSArray subclass, so counting it through the
// runtime is legitimate. Every failure path (different nav class, missing
// ivar on a future Apollo, nil/empty array) returns NO, which keeps the
// carousel's native rubber-band.
static BOOL ApolloFeedGalleryCanGoForward(UINavigationController *navigationController) {
    id popped = ApolloFeedGalleryObjectIvar(navigationController, "poppedViewControllers");
    if (![popped respondsToSelector:@selector(count)]) return NO;
    @try {
        return ((NSUInteger (*)(id, SEL))objc_msgSend)(popped, @selector(count)) > 0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@interface ApolloFeedGalleryScrollView : UIScrollView
@end

@implementation ApolloFeedGalleryScrollView

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    // A touch landing on the page image must still be allowed to turn into a
    // carousel drag. There is no reorder interaction to preserve here.
    (void)view;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.panGestureRecognizer && sFeedGalleryEdgeSwipeNav) {
        // The carousel owns a horizontal drag only while it still has a page
        // to show in that direction. At the first/last page the drag could
        // only rubber-band, so decline it: the failure requirements wired in
        // didMoveToWindow then release Apollo's own back/forward navigation
        // pans (ApolloNavigationController's left/right pan recognizers) to
        // take over the same touch. Only decline when that navigation can
        // actually act; otherwise keep the native bounce.
        //
        // Direction comes from the velocity sign (translationInView: is still
        // zero at pan-hysteresis time), taken only above a magnitude floor:
        // hysteresis velocity can read as zero or momentarily backwards for
        // real fingers, and a false hand-off navigates the user away, which
        // is worse than a bounce. Anything below the floor falls through to
        // the deterministic release-past-edge path in the scroll delegate.
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
        CGFloat velocityX = [pan velocityInView:self].x;
        CGFloat maximumOffset = self.contentSize.width - CGRectGetWidth(self.bounds);
        if (maximumOffset > 0.5 &&
            fabs(velocityX) >= kApolloFeedGalleryHandOffMinimumVelocity) {
            // Pages are laid out left-to-right in every locale (see
            // layoutSubviews), so the first image sits at offset 0 even under
            // RTL. Only the NAVIGATION meaning of pulling past an edge
            // mirrors with the layout direction, not the edges themselves.
            BOOL atFirstPage = self.contentOffset.x <= 0.5;
            BOOL atLastPage = self.contentOffset.x >= maximumOffset - 0.5;
            BOOL pullingPastLeading = atFirstPage && velocityX > 0.0;
            BOOL pullingPastTrailing = atLastPage && velocityX < 0.0;
            BOOL rightToLeft = self.effectiveUserInterfaceLayoutDirection ==
                UIUserInterfaceLayoutDirectionRightToLeft;
            BOOL wantsBack = rightToLeft ? pullingPastTrailing : pullingPastLeading;
            BOOL wantsForward = rightToLeft ? pullingPastLeading : pullingPastTrailing;
            if (wantsBack || wantsForward) {
                UINavigationController *navigationController =
                    ApolloFeedGalleryAncestorNavigationController(self);
                // Never hand off while a transition is already running (the
                // carousel can be asked again mid-pop as its screen animates
                // away; a second decline would double-pop).
                BOOL navigationCanAct = navigationController.transitionCoordinator == nil &&
                    (wantsBack
                    ? navigationController.viewControllers.count > 1
                    : ApolloFeedGalleryCanGoForward(navigationController));
                if (navigationCanAct) {
                    ApolloLog(@"[FeedGallery] handing %@ swipe to navigation (offset=%.0f)",
                              wantsBack ? @"back" : @"forward", self.contentOffset.x);
                    return NO;
                }
            }
        }
    }
    return [super gestureRecognizerShouldBegin:gestureRecognizer];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;

    // Apply this only after the asynchronously-created Texture view reaches
    // its real hierarchy. The previous begin-time velocity decision was made
    // once at pan hysteresis and permanently rejected otherwise-good swipes
    // when a finger's first few points contained vertical jitter. UIKit's
    // nested-scroll direction lock is stable once both pans get to compete.
    self.delaysContentTouches = NO;
    self.canCancelContentTouches = YES;

    UIPanGestureRecognizer *carouselPan = self.panGestureRecognizer;
    NSUInteger preferredOver = 0;
    for (UIView *ancestor = self.superview; ancestor; ancestor = ancestor.superview) {
        for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
            if (recognizer == carouselPan) continue;
            if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            // Do not gate the feed's own scroll pan: doing so eats vertical
            // drags that start over a gallery. Do not gate navigation's edge or
            // content-back pans either: UIKit implements both as
            // UIScreenEdgePanGestureRecognizer subclasses and dynamically
            // arbitrates them against scroll views at their leading boundary.
            // Keeping that native arbitration means page 2+ swipes to the
            // previous image, while a navigation-originated swipe at page 1 can
            // go back. A permanent failure requirement would instead make every
            // carousel on the screen block navigation, even when untouched.
            if ([recognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) continue;
            UIView *recognizerView = recognizer.view;
            if ([recognizerView isKindOfClass:[UIScrollView class]] &&
                recognizer == ((UIScrollView *)recognizerView).panGestureRecognizer) continue;
            [recognizer requireGestureRecognizerToFail:carouselPan];
            preferredOver++;
        }
    }
    ApolloLog(@"[FeedGallery] carousel attached; preferred over %lu ancestor pans",
              (unsigned long)preferredOver);
}

@end

#pragma mark - Carousel view

@interface ApolloFeedGalleryCarouselView : UIView <UIScrollViewDelegate>
@property (nonatomic, weak) id albumNode;
@property (nonatomic, strong) ApolloFeedGalleryScrollView *scrollView;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *imageViews;
@property (nonatomic, strong) NSMutableArray *loadedURLs;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) UIVisualEffectView *obscureBlurView;
@property (nonatomic, strong) UIButton *obscureButton;
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) BOOL contentIsObscured;
@property (nonatomic) CGSize lastLayoutSize;
@property (nonatomic) BOOL needsPageGeometry;
@property (nonatomic) BOOL dragBeganAtLeadingEdge;
@property (nonatomic) BOOL dragBeganAtTrailingEdge;
- (void)configureWithItems:(NSArray<NSDictionary *> *)items
                 albumNode:(id)albumNode
                      nsfw:(BOOL)nsfw
                   spoiler:(BOOL)spoiler;
@end

@implementation ApolloFeedGalleryCarouselView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.blackColor;
    self.accessibilityIdentifier = @"ApolloFeedGalleryCarousel";
    self.shouldGroupAccessibilityChildren = YES;

    _scrollView = [[ApolloFeedGalleryScrollView alloc] initWithFrame:self.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.pagingEnabled = YES;
    _scrollView.directionalLockEnabled = YES;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.delegate = self;
    if (@available(iOS 11.0, *)) {
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self addSubview:_scrollView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_pageTapped:)];
    // This tap replaces Apollo's enclosing feed-card tap. Letting both survive
    // can start a post push while the media presentation is beginning, which
    // leaves UIKit with overlapping appearance transitions.
    tap.cancelsTouchesInView = YES;
    [_scrollView addGestureRecognizer:tap];

    _pageControl = [[UIPageControl alloc] initWithFrame:CGRectZero];
    if (@available(iOS 14.0, *)) _pageControl.backgroundStyle = UIPageControlBackgroundStyleMinimal;
    [_pageControl addTarget:self action:@selector(apollo_pageControlChanged:)
           forControlEvents:UIControlEventValueChanged];
    [self addSubview:_pageControl];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    _countLabel.textColor = UIColor.whiteColor;
    _countLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _countLabel.textAlignment = NSTextAlignmentCenter;
    _countLabel.layer.cornerRadius = 13.0;
    _countLabel.clipsToBounds = YES;
    _countLabel.isAccessibilityElement = NO;
    [self addSubview:_countLabel];

    _imageViews = [NSMutableArray array];
    _loadedURLs = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    [self apollo_cancelRequests];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0.0 || height <= 0.0) return;

    CGSize size = self.bounds.size;
    // Covers can be installed after the page geometry has already settled.
    // Keep their frame current even when no page relayout is needed.
    self.obscureBlurView.frame = self.bounds;
    self.obscureButton.frame = self.bounds;
    BOOL sizeChanged = !CGSizeEqualToSize(size, self.lastLayoutSize);
    if (!sizeChanged && !self.needsPageGeometry) return;

    CGFloat oldWidth = self.lastLayoutSize.width;
    CGFloat pagePosition = self.currentIndex;
    if (!self.needsPageGeometry && oldWidth > 0.0) {
        pagePosition = self.scrollView.contentOffset.x / oldWidth;
    }

    [self.imageViews enumerateObjectsUsingBlock:^(UIImageView *imageView, NSUInteger index, BOOL *stop) {
        imageView.frame = CGRectMake(width * index, 0.0, width, height);
    }];
    self.scrollView.contentSize = CGSizeMake(width * self.imageViews.count, height);
    // The offset is only written on a real geometry change (the same-size
    // early-return above guarantees that), preserving the fractional page so
    // width changes keep the visual position. Ordinary layout passes never
    // reach this line — snapping the offset from them fought UIScrollView's
    // interactive/decelerating state and was the largest source of judder.
    self.scrollView.contentOffset = CGPointMake(width * pagePosition, 0.0);

    self.pageControl.frame = CGRectMake(44.0, height - 30.0, MAX(0.0, width - 88.0), 24.0);
    self.countLabel.frame = CGRectMake(width - 58.0, 10.0, 48.0, 26.0);
    self.lastLayoutSize = size;
    self.needsPageGeometry = NO;
}

- (void)configureWithItems:(NSArray<NSDictionary *> *)items
                 albumNode:(id)albumNode
                      nsfw:(BOOL)nsfw
                   spoiler:(BOOL)spoiler {
    NSAssert(NSThread.isMainThread, @"Feed gallery carousel must be configured on the main thread");
    self.albumNode = albumNode;

    if (self.items != items) {
        [self apollo_cancelRequests];
        [self.imageViews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        [self.imageViews removeAllObjects];
        [self.loadedURLs removeAllObjects];
        self.items = [items copy];
        self.currentIndex = 0;
        self.needsPageGeometry = YES;

        for (NSUInteger index = 0; index < items.count; index++) {
            UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
            imageView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.clipsToBounds = YES;
            imageView.isAccessibilityElement = YES;
            imageView.accessibilityLabel = [NSString stringWithFormat:@"Gallery image %lu of %lu",
                                            (unsigned long)index + 1, (unsigned long)items.count];
            imageView.accessibilityTraits = UIAccessibilityTraitImage | UIAccessibilityTraitButton;
            [self.scrollView addSubview:imageView];
            [self.imageViews addObject:imageView];
            [self.loadedURLs addObject:[NSNull null]];
        }
    }

    RDKLink *link = ApolloFeedGalleryLink(albumNode);
    BOOL alreadyRevealed = [objc_getAssociatedObject(link, &kApolloFeedGalleryRevealKey) boolValue];
    [self apollo_setObscured:(nsfw || spoiler) && !alreadyRevealed nsfw:nsfw spoiler:spoiler];
    self.pageControl.numberOfPages = items.count;
    self.pageControl.currentPage = self.currentIndex;
    [self apollo_updateCount];
    [self setNeedsLayout];
}

- (void)apollo_setObscured:(BOOL)obscured nsfw:(BOOL)nsfw spoiler:(BOOL)spoiler {
    self.contentIsObscured = obscured;
    self.scrollView.scrollEnabled = !obscured;
    if (!obscured) {
        UIVisualEffectView *blurView = self.obscureBlurView;
        UIButton *coverButton = self.obscureButton;
        self.obscureBlurView = nil;
        self.obscureButton = nil;
        if (blurView || coverButton) {
            coverButton.userInteractionEnabled = NO;
            void (^tearDown)(void) = ^{
                [blurView removeFromSuperview];
                [coverButton removeFromSuperview];
            };
            if (UIAccessibilityIsReduceMotionEnabled()) {
                tearDown();
            } else {
                // Match Apollo's animated obscured-content reveal instead of a
                // one-frame pop.
                [UIView animateWithDuration:0.25 animations:^{
                    blurView.alpha = 0.0;
                    coverButton.alpha = 0.0;
                } completion:^(__unused BOOL finished) {
                    tearDown();
                }];
            }
        }
        if (self.window) [self apollo_loadNearIndex:self.currentIndex];
        return;
    }

    // This is both a privacy boundary and a memory/performance win: obscured
    // NSFW/spoiler cards do not download or retain pixels behind the cover.
    [self apollo_releaseImagesOutsideLowerBound:NSNotFound upperBound:NSNotFound];

    // Install the blur/cover synchronously before image completions can paint.
    // Under Reduce Transparency the cover is an opaque fill instead of a blur.
    if (!self.obscureBlurView) {
        BOOL opaqueCover = UIAccessibilityIsReduceTransparencyEnabled();
        UIBlurEffect *effect = opaqueCover ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.obscureBlurView = [[UIVisualEffectView alloc] initWithEffect:effect];
        if (opaqueCover) {
            self.obscureBlurView.contentView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        }
        self.obscureBlurView.userInteractionEnabled = NO;
        [self addSubview:self.obscureBlurView];
    }
    if (!self.obscureButton) {
        self.obscureButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.obscureButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
        self.obscureButton.tintColor = UIColor.whiteColor;
        self.obscureButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        self.obscureButton.titleLabel.numberOfLines = 2;
        self.obscureButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        [self.obscureButton addTarget:self action:@selector(apollo_revealTapped:)
                     forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.obscureButton];
    }
    NSString *title = nsfw && spoiler ? @"Spoiler and NSFW\nTap to view"
                      : nsfw ? @"NSFW\nTap to view"
                             : @"Spoiler\nTap to view";
    [self.obscureButton setTitle:title forState:UIControlStateNormal];
    self.obscureButton.accessibilityLabel = [title stringByReplacingOccurrencesOfString:@"\n" withString:@". "];
    [self bringSubviewToFront:self.obscureBlurView];
    [self bringSubviewToFront:self.obscureButton];
}

- (void)apollo_revealTapped:(id)sender {
    RDKLink *link = ApolloFeedGalleryLink(self.albumNode);
    if (link) objc_setAssociatedObject(link, &kApolloFeedGalleryRevealKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self apollo_setObscured:NO nsfw:NO spoiler:NO];
    [self apollo_loadNearIndex:self.currentIndex];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.imageViews[self.currentIndex]);
    ApolloLog(@"[FeedGallery] obscured gallery revealed by user");
}

- (void)apollo_pageTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded || self.contentIsObscured) return;
    NSInteger index = self.currentIndex;
    if (index < 0 || index >= (NSInteger)self.items.count) return;

    id richMediaNode = ApolloFeedGalleryRichMediaNode(self.albumNode);
    RDKLink *link = ApolloFeedGalleryObjectIvar(richMediaNode, "link");

    // Apollo's tap route maps the sender's identity against thumbnailNode1..3
    // to pick the opening page, builds the viewer's placeholder dictionary as
    // [index: sender.image], and uses the sender's view as the zoom-transition
    // source (RE: sub_10058c634 / sub_100321eac). So for pages 0-2, passing
    // the MATCHING native node gives the correct index natively — no ivar
    // seeding — and whatever image/frame the sender carries becomes the
    // placeholder and the zoom origin. Feed it the carousel's already-decoded
    // page image and the tapped page's on-screen rect.
    const char *senderNames[3] = { "thumbnailNode1", "thumbnailNode2", "thumbnailNode3" };
    id senderNode = index <= 2
        ? ApolloFeedGalleryObjectIvar(self.albumNode, senderNames[index]) : nil;
    BOOL senderMapsNatively = senderNode != nil;
    if (!senderNode) senderNode = ApolloFeedGalleryObjectIvar(self.albumNode, "thumbnailNode1");
    if (!richMediaNode || !senderNode || !link ||
        ![richMediaNode respondsToSelector:@selector(albumThumbnailButtonTappedWithSender:)]) {
        ApolloLog(@"[FeedGallery] cannot open native viewer: missing owner/thumbnail/link");
        return;
    }

    UIImageView *pageView = self.imageViews[index];
    if (pageView.image && [senderNode respondsToSelector:@selector(setImage:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(senderNode, @selector(setImage:), pageView.image);
    }
    UIView *senderView = [senderNode respondsToSelector:@selector(view)]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(senderNode, @selector(view)) : nil;
    if (senderView.superview && pageView.window) {
        senderView.frame = [senderView.superview convertRect:pageView.bounds fromView:pageView];
    }

    // Pages >= 3 have no matching native sender; seed the pager's index ivar
    // via the viewDidLoad hook instead (guarded, see CanWriteOptionalIndexIvar).
    if (!senderMapsNatively) {
        ApolloFeedGalleryPendingSelection *selection = [[ApolloFeedGalleryPendingSelection alloc] init];
        selection.index = index;
        objc_setAssociatedObject(link, &kApolloFeedGalleryPendingViewerIndexKey,
                                 selection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The native route allocates and presents the pager synchronously, so
        // viewDidLoad consumes this within the current turn; one hop later it
        // can only be stale.
        __weak RDKLink *weakLink = link;
        dispatch_async(dispatch_get_main_queue(), ^{
            RDKLink *innerLink = weakLink;
            if (innerLink && objc_getAssociatedObject(innerLink, &kApolloFeedGalleryPendingViewerIndexKey) == selection) {
                objc_setAssociatedObject(innerLink, &kApolloFeedGalleryPendingViewerIndexKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[FeedGallery] cleared stale native-viewer selection");
            }
        });
    }
    ApolloLog(@"[FeedGallery] opening native viewer requestedIndex=%ld nativeSender=%d",
              (long)index, (int)senderMapsNatively);
    ((void (*)(id, SEL, id))objc_msgSend)(richMediaNode,
                                         @selector(albumThumbnailButtonTappedWithSender:),
                                         senderNode);
}

- (void)apollo_cancelRequests {
    if (!sApolloFeedGalleryPINAvailable) return;
    for (UIImageView *imageView in self.imageViews) {
        [imageView pin_cancelImageDownload];
    }
}

- (void)apollo_releaseImagesOutsideLowerBound:(NSInteger)lower upperBound:(NSInteger)upper {
    for (NSInteger index = 0; index < (NSInteger)self.imageViews.count; index++) {
        BOOL keep = lower != NSNotFound && index >= lower && index <= upper;
        if (keep) continue;
        UIImageView *imageView = self.imageViews[index];
        if (sApolloFeedGalleryPINAvailable) [imageView pin_cancelImageDownload];
        imageView.image = nil;
        if (index < (NSInteger)self.loadedURLs.count) self.loadedURLs[index] = NSNull.null;
    }
}

- (void)apollo_loadNearIndex:(NSInteger)index {
    if (self.items.count == 0 || self.contentIsObscured || !self.window) return;
    NSInteger lower = MAX(0, index - 1);
    NSInteger upper = MIN((NSInteger)self.items.count - 1, index + 1);
    for (NSInteger candidate = lower; candidate <= upper; candidate++) {
        if (candidate >= (NSInteger)self.loadedURLs.count || self.loadedURLs[candidate] != [NSNull null]) continue;
        NSURL *URL = self.items[candidate][@"previewURL"];
        UIImageView *imageView = self.imageViews[candidate];
        self.loadedURLs[candidate] = URL;
        imageView.image = nil;
        if (sApolloFeedGalleryPINAvailable) [imageView pin_setImageFromURL:URL];
    }
}

- (NSInteger)apollo_clampIndex:(NSInteger)index {
    return MAX(0, MIN((NSInteger)self.items.count - 1, index));
}

- (void)apollo_pageControlChanged:(UIPageControl *)pageControl {
    NSInteger target = [self apollo_clampIndex:pageControl.currentPage];
    CGFloat width = CGRectGetWidth(self.scrollView.bounds);
    if (width <= 0.0) return;
    [self apollo_loadNearIndex:target];
    [self.scrollView setContentOffset:CGPointMake(width * target, 0.0) animated:YES];
}

- (void)apollo_finishPaging {
    if (self.items.count == 0) return;
    CGFloat width = CGRectGetWidth(self.scrollView.bounds);
    if (width > 0.0) {
        self.currentIndex = [self apollo_clampIndex:
            (NSInteger)llround(self.scrollView.contentOffset.x / width)];
    }
    [self apollo_loadNearIndex:self.currentIndex];
    NSInteger lower = MAX(0, self.currentIndex - 2);
    NSInteger upper = [self apollo_clampIndex:self.currentIndex + 2];
    [self apollo_releaseImagesOutsideLowerBound:lower upperBound:upper];
}

- (void)apollo_updateCount {
    NSInteger count = self.items.count;
    self.countLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)self.currentIndex + 1, (long)count];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat width = CGRectGetWidth(scrollView.bounds);
    if (width <= 0.0 || self.items.count == 0) return;
    NSInteger index = [self apollo_clampIndex:(NSInteger)llround(scrollView.contentOffset.x / width)];
    if (index == self.currentIndex) return;
    self.currentIndex = index;
    self.pageControl.currentPage = index;
    [self apollo_updateCount];
    // A fast fling crosses many pages; starting +/-1 downloads for each one
    // wastes the network on images that are never seen.
    // scrollViewWillEndDragging: already prefetched the landing page and
    // apollo_finishPaging reconciles when the scroll settles.
    if (!scrollView.isDecelerating) [self apollo_loadNearIndex:index];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self.scrollView) return;
    CGFloat maximumOffset = scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds);
    self.dragBeganAtLeadingEdge = maximumOffset > 0.5 && scrollView.contentOffset.x <= 0.5;
    self.dragBeganAtTrailingEdge = maximumOffset > 0.5 &&
        scrollView.contentOffset.x >= maximumOffset - 0.5;
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView != self.scrollView || !targetContentOffset) return;
    CGFloat width = CGRectGetWidth(scrollView.bounds);
    if (width <= 0.0) return;
    [self apollo_loadNearIndex:[self apollo_clampIndex:(NSInteger)llround(targetContentOffset->x / width)]];
}

// Deterministic companion to the begin-time handoff above: when that decline
// misses (a real finger's velocity at pan-hysteresis can read as zero or
// momentarily backwards, so the carousel takes the drag and rubber-bands),
// releasing while still pulled past the first/last page commits to the same
// navigation. Release-time state is unambiguous — no velocity guessing.
- (void)apollo_navigateIfReleasedPastEdge:(UIScrollView *)scrollView {
    if (!sFeedGalleryEdgeSwipeNav) return;
    if (!self.dragBeganAtLeadingEdge && !self.dragBeganAtTrailingEdge) return;
    CGFloat maximumOffset = scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds);
    if (maximumOffset <= 0.5) return;
    CGFloat offset = scrollView.contentOffset.x;
    BOOL pastLeading = self.dragBeganAtLeadingEdge &&
        offset < -kApolloFeedGalleryReleaseHandOffOverscroll;
    BOOL pastTrailing = self.dragBeganAtTrailingEdge &&
        offset > maximumOffset + kApolloFeedGalleryReleaseHandOffOverscroll;
    if (!pastLeading && !pastTrailing) return;

    BOOL rightToLeft = self.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft;
    BOOL wantsBack = rightToLeft ? pastTrailing : pastLeading;
    UINavigationController *navigationController =
        ApolloFeedGalleryAncestorNavigationController(self);
    // A transition already in flight means an earlier gesture won this
    // navigation; firing again would double-pop.
    if (navigationController.transitionCoordinator) return;
    if (wantsBack) {
        if (navigationController.viewControllers.count <= 1) return;
        ApolloLog(@"[FeedGallery] released past edge; navigating back (overscroll=%.0f)",
                  pastLeading ? -offset : offset - maximumOffset);
        [navigationController popViewControllerAnimated:YES];
    } else {
        if (!ApolloFeedGalleryCanGoForward(navigationController)) return;
        if (![navigationController respondsToSelector:@selector(goForward)]) return;
        ApolloLog(@"[FeedGallery] released past edge; navigating forward (overscroll=%.0f)",
                  pastLeading ? -offset : offset - maximumOffset);
        ((void (*)(id, SEL))objc_msgSend)(navigationController, @selector(goForward));
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView != self.scrollView) return;
    [self apollo_navigateIfReleasedPastEdge:scrollView];
    self.dragBeganAtLeadingEdge = NO;
    self.dragBeganAtTrailingEdge = NO;
    if (!decelerate) [self apollo_finishPaging];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == self.scrollView) [self apollo_finishPaging];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (scrollView == self.scrollView) [self apollo_finishPaging];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow) {
        [self apollo_releaseImagesOutsideLowerBound:NSNotFound upperBound:NSNotFound];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !self.contentIsObscured) [self apollo_loadNearIndex:self.currentIndex];
}

@end

#pragma mark - Texture host and live setting refresh

static NSHashTable *ApolloFeedGalleryTrackedNodes(void) {
    static NSHashTable *nodes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nodes = [NSHashTable weakObjectsHashTable]; });
    return nodes;
}

static ASDisplayNode *ApolloFeedGalleryEnsureHostNode(id albumNode) {
    ASDisplayNode *host = nil;
    BOOL created = NO;
    // Texture measures concurrently; the get-or-create must be atomic or two
    // background passes race to install two hosts (one orphaned with a live
    // carousel).
    @synchronized (albumNode) {
        host = objc_getAssociatedObject(albumNode, &kApolloFeedGalleryHostNodeKey);
        if (!host) {
            Class nodeClass = NSClassFromString(@"ASDisplayNode");
            if (!nodeClass) return nil;
            host = [[nodeClass alloc] init];
            host.userInteractionEnabled = YES;
            objc_setAssociatedObject(albumNode, &kApolloFeedGalleryHostNodeKey, host,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            created = YES;
        }
    }
    if (created) {
        // Off-main node-tree mutation is only legal while the album node's
        // view is unloaded (the normal first-measurement case). The loaded
        // case is reachable when the user toggles the setting on while the
        // cell is on screen — attach on main and let the pending relayout
        // pick the host up.
        BOOL loaded = [albumNode respondsToSelector:@selector(isNodeLoaded)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(albumNode, @selector(isNodeLoaded));
        if (!loaded || NSThread.isMainThread) {
            [albumNode addSubnode:host];
        } else {
            __weak id weakAlbumNode = albumNode;
            dispatch_async(dispatch_get_main_queue(), ^{
                id strongAlbumNode = weakAlbumNode;
                if (strongAlbumNode) [strongAlbumNode addSubnode:host];
            });
        }
    }
    return host;
}

static void ApolloFeedGalleryScheduleApply(ASDisplayNode *host,
                                           id albumNode,
                                           NSArray<NSDictionary *> *items,
                                           BOOL enabled,
                                           BOOL nsfw,
                                           BOOL spoiler) {
    if (!host || !albumNode) return;

    __block ApolloFeedGalleryApplyState *state = nil;
    @synchronized (host) {
        ApolloFeedGalleryApplyState *existing = objc_getAssociatedObject(
            host, &kApolloFeedGalleryApplyStateKey);
        if (existing && existing.albumNode == albumNode && existing.items == items &&
            existing.enabled == enabled && existing.nsfw == nsfw && existing.spoiler == spoiler) {
            return;
        }
        state = [[ApolloFeedGalleryApplyState alloc] init];
        state.albumNode = albumNode;
        state.items = items;
        state.enabled = enabled;
        state.nsfw = nsfw;
        state.spoiler = spoiler;
        objc_setAssociatedObject(host, &kApolloFeedGalleryApplyStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Texture can measure on a background queue. Coalesce repeated measurements
    // into one main-thread mutation; stale queued states simply self-cancel.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(host, &kApolloFeedGalleryApplyStateKey) != state) return;
        for (NSString *name in @[ @"thumbnailNode1", @"thumbnailNode2", @"thumbnailNode3",
                                  @"totalImagesNode", @"obscuredContentInfoOverlayNode" ]) {
            ASDisplayNode *node = ApolloFeedGalleryObjectIvar(albumNode, name.UTF8String);
            if (node) node.hidden = enabled;
        }
        host.hidden = !enabled;
        if (!enabled) {
            // Fully tear down so up to N decoded full-width images release
            // immediately instead of staying resident behind a hidden host.
            ApolloFeedGalleryCarouselView *existing = objc_getAssociatedObject(
                host, &kApolloFeedGalleryViewKey);
            if (existing) {
                [existing removeFromSuperview];
                objc_setAssociatedObject(host, &kApolloFeedGalleryViewKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return;
        }

        UIView *hostView = host.view;
        if (!hostView) return;
        hostView.clipsToBounds = YES;
        ApolloFeedGalleryCarouselView *carousel = objc_getAssociatedObject(host, &kApolloFeedGalleryViewKey);
        if (!carousel) {
            carousel = [[ApolloFeedGalleryCarouselView alloc] initWithFrame:hostView.bounds];
            carousel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [hostView addSubview:carousel];
            objc_setAssociatedObject(host, &kApolloFeedGalleryViewKey, carousel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        carousel.frame = hostView.bounds;
        [carousel configureWithItems:items albumNode:albumNode nsfw:nsfw spoiler:spoiler];
    });
}

// Always invoked on the main queue (the %ctor observer registers with
// NSOperationQueue.mainQueue). Nodes outside Texture's working range pick the
// change up when they re-enter it; that deferred application is inherent to
// Texture's range-based measurement.
static void ApolloFeedGallerySettingChanged(void) {
    NSArray *snapshot = nil;
    @synchronized (ApolloFeedGalleryTrackedNodes()) {
        snapshot = ApolloFeedGalleryTrackedNodes().allObjects;
    }
    for (ASDisplayNode *node in snapshot) [node setNeedsLayout];
}

#pragma mark - Hooks

%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloFeedGallerySizeRange)constrainedSize {
    // Texture does not guarantee AlbumThumbnailsNode.supernode is connected
    // when the child's background layout pass starts. Capture the owner from
    // the parent BEFORE its original layout triggers child measurement; a weak
    // box avoids a RichMedia <-> album cycle.
    id albumNode = ApolloFeedGalleryObjectIvar(self, "albumThumbnailsNode");
    if (albumNode) {
        ApolloFeedGalleryOwnerBox *box = objc_getAssociatedObject(albumNode, &kApolloFeedGalleryOwnerBoxKey);
        if (!box) {
            box = [[ApolloFeedGalleryOwnerBox alloc] init];
            objc_setAssociatedObject(albumNode, &kApolloFeedGalleryOwnerBoxKey, box,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        box.owner = self;
    }
    return %orig;
}

%end

%hook _TtC6Apollo19AlbumThumbnailsNode

- (id)layoutSpecThatFits:(struct ApolloFeedGallerySizeRange)constrainedSize {
    if (![objc_getAssociatedObject(self, &kApolloFeedGalleryTrackedNodeKey) boolValue]) {
        @synchronized (ApolloFeedGalleryTrackedNodes()) {
            if (![objc_getAssociatedObject(self, &kApolloFeedGalleryTrackedNodeKey) boolValue]) {
                [ApolloFeedGalleryTrackedNodes() addObject:self];
                objc_setAssociatedObject(self, &kApolloFeedGalleryTrackedNodeKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }

    // All gates run BEFORE %orig: in the enabled path Apollo's native
    // three-image mosaic spec would be built on every measurement pass while
    // scrolling and then thrown away.
    ASDisplayNode *existingHost = objc_getAssociatedObject(self, &kApolloFeedGalleryHostNodeKey);
    if (!sFeedGalleryCarousel || !sApolloFeedGalleryPINAvailable) {
        if (existingHost) ApolloFeedGalleryScheduleApply(existingHost, self, nil, NO, NO, NO);
        return %orig;
    }

    id richMediaNode = ApolloFeedGalleryRichMediaNode(self);
    // AlbumThumbnailsNode is reused in comments' rich-media header. This first
    // scope intentionally changes only large feed cards.
    if (!richMediaNode || ApolloFeedGalleryBoolIvar(richMediaNode, "isShownInCommentsHeader")) {
        if (existingHost) ApolloFeedGalleryScheduleApply(existingHost, self, nil, NO, NO, NO);
        return %orig;
    }

    NSArray<NSDictionary *> *items = ApolloFeedGalleryItems(self);
    if (items.count < 2) {
        if (existingHost) ApolloFeedGalleryScheduleApply(existingHost, self, nil, NO, NO, NO);
        return %orig;
    }

    ASDisplayNode *host = existingHost ?: ApolloFeedGalleryEnsureHostNode(self);
    Class ratioClass = NSClassFromString(@"ASRatioLayoutSpec");
    if (!host || !ratioClass) return %orig;

    BOOL nsfw = ApolloFeedGalleryBoolIvar(self, "isNSFW");
    BOOL spoiler = ApolloFeedGalleryBoolIvar(self, "isSpoiler");
    if (!existingHost) {
        ApolloLog(@"[FeedGallery] installing carousel count=%lu obscured=%d",
                  (unsigned long)items.count, (int)(nsfw || spoiler));
    }
    ApolloFeedGalleryScheduleApply(host, self, items, YES, nsfw, spoiler);

    id replacement = [ratioClass ratioLayoutSpecWithRatio:ApolloFeedGalleryRatioForItems(items)
                                                    child:host];
    return replacement ?: %orig;
}

- (void)layout {
    %orig;
    // Limit frame maintenance to Apollo's album nodes. The previous global
    // ASDisplayNode hook ran an associated-object lookup for every Texture node
    // in the app during scrolling.
    ASDisplayNode *host = objc_getAssociatedObject(self, &kApolloFeedGalleryHostNodeKey);
    ApolloFeedGalleryCarouselView *carousel = objc_getAssociatedObject(host, &kApolloFeedGalleryViewKey);
    if (!carousel) return;
    CGRect bounds = host.view.bounds;
    if (!CGRectEqualToRect(carousel.frame, bounds)) carousel.frame = bounds;
}

%end

%hook _TtC6Apollo23MediaPageViewController

- (void)viewDidLoad {
    RDKLink *link = ApolloFeedGalleryObjectIvar(self, "link");
    ApolloFeedGalleryPendingSelection *selection = objc_getAssociatedObject(
        link, &kApolloFeedGalleryPendingViewerIndexKey);
    if ([selection isKindOfClass:[ApolloFeedGalleryPendingSelection class]]) {
        objc_setAssociatedObject(link, &kApolloFeedGalleryPendingViewerIndexKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Ivar selectedIvar = class_getInstanceVariable([self class], "selectedThumbnailIndex");
        if (selectedIvar && ApolloFeedGalleryCanWriteOptionalIndexIvar([self class], selectedIvar)) {
            uint8_t *slot = (uint8_t *)(__bridge void *)self + ivar_getOffset(selectedIvar);
            *(NSInteger *)slot = MAX(0, selection.index);
            slot[sizeof(NSInteger)] = 0; // Swift.Optional<Int>.some discriminator
            ApolloLog(@"[FeedGallery] seeded native viewer requestedIndex=%ld",
                      (long)selection.index);
        } else {
            ApolloLog(@"[FeedGallery] native viewer index layout unexpected; opening at native index");
        }
    }
    %orig;
}

%end

%ctor {
    sApolloFeedGalleryPINAvailable =
        [UIImageView instancesRespondToSelector:@selector(pin_setImageFromURL:)] &&
        [UIImageView instancesRespondToSelector:@selector(pin_cancelImageDownload)];
    ApolloLog(@"[FeedGallery] loaded enabled=%d pinAvailable=%d",
              (int)sFeedGalleryCarousel, (int)sApolloFeedGalleryPINAvailable);
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloFeedGalleryCarouselChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloFeedGallerySettingChanged();
    }];
}
