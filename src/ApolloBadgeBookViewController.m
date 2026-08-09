#import "ApolloBadgeBookViewController.h"
#import "ApolloBadgeBookCatalog.h"
#import "ApolloBadgeBookScraper.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloAccountCredentials.h"   // ApolloActiveAccountUsername() — locked-note wording
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Async downsampled image loader (remote badge/trophy art)

// The bundled catalogue icons are tiny and load synchronously. Remote images are
// the handful of live/uncatalogued trophies a profile may show, plus real art for
// "ghost" achievements (Reddit only serves their art on profiles that earned
// them). Load off-main and downsample via ImageIO so a 1024px source never
// becomes a main-thread decode or a memory spike.
static NSCache<NSString *, UIImage *> *ApolloBBRemoteImageCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 120;
        cache.totalCostLimit = 16 * 1024 * 1024;   // decoded thumbs; evictable under pressure
    });
    return cache;
}

// In-flight dedup: main-thread map of cacheKey -> waiting completions. The
// cache stores only DECODED results, so without this a fast scroll bounce
// through uncatalogued trophies (or the grid + detail card racing on the same
// art) re-downloads the same URL once per caller until the first response
// lands. Same pattern as the scraper's ApolloBBPending().
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloBBRemoteImagePending(void) {
    static NSMutableDictionary *pending; static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}

static void ApolloBBLoadRemoteImage(NSString *urlString, CGFloat pointSize, void (^completion)(UIImage *)) {
    if (urlString.length == 0) { if (completion) completion(nil); return; }
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat maxPixels = MAX(64.0, pointSize * scale);
    // Keyed by URL AND decode size: the grid warms 64pt thumbs, and serving one
    // of those to the 132pt detail card is a visibly soft upscale at 3x.
    NSString *cacheKey = [NSString stringWithFormat:@"%.0f|%@", maxPixels, urlString];
    UIImage *cached = [ApolloBBRemoteImageCache() objectForKey:cacheKey];
    if (cached) { if (completion) completion(cached); return; }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { if (completion) completion(nil); return; }

    // All callers are main-thread UI code, so the pending map needs no lock.
    NSMutableArray *waiters = ApolloBBRemoteImagePending()[cacheKey];
    if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }
    waiters = [NSMutableArray array];
    if (completion) [waiters addObject:[completion copy]];
    ApolloBBRemoteImagePending()[cacheKey] = waiters;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        UIImage *image = nil;
        NSUInteger cost = 0;
        if (data.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                NSDictionary *opts = @{
                    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                    (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                    (id)kCGImageSourceShouldCacheImmediately: @YES,
                    (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixels),
                };
                CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                if (cg) {
                    image = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
                    cost = CGImageGetBytesPerRow(cg) * CGImageGetHeight(cg);
                    CGImageRelease(cg);
                }
                CFRelease(src);
            }
        }
        if (image) [ApolloBBRemoteImageCache() setObject:image forKey:cacheKey cost:cost];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *toNotify = ApolloBBRemoteImagePending()[cacheKey];
            [ApolloBBRemoteImagePending() removeObjectForKey:cacheKey];
            for (void (^waiter)(UIImage *) in toNotify) waiter(image);
        });
    }];
    [task resume];
}

#pragma mark - Badge state

typedef NS_ENUM(NSInteger, ApolloBadgeState) {
    ApolloBadgeStateUnknown = 0,   // earned/locked not yet resolved — show plainly, no lock
    ApolloBadgeStateEarned  = 1,
    ApolloBadgeStateLocked  = 2,
};

static UIColor *ApolloBBAccent(UIView *view) {
    return ApolloThemeAccentColor() ?: view.tintColor ?: [UIColor systemBlueColor];
}

#pragma mark - Ambient theme

// The Badge Book must match whatever theme Apollo is currently painting — the
// tweak's custom themes AND the stock ones. Custom themes serve concrete tokens
// (ApolloThemeRuntimeColor); stock themes are painted by Apollo's own code, so
// the background is SAMPLED from the presenting profile hierarchy (the same
// inherit-the-ambient-theme approach the Theme Manager uses for settings), and
// surfaces are derived from it.

static BOOL ApolloBBColorRGBA(UIColor *c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w = 0.0, alpha = 0.0;
    if ([c getWhite:&w alpha:&alpha]) { *r = *g = *b = w; *a = alpha; return YES; }
    return NO;
}

static UIColor *ApolloBBOpaqueBackgroundOf(UIView *v) {
    UIColor *bg = v.backgroundColor;
    if (!bg) return nil;
    UIColor *resolved = [bg resolvedColorWithTraitCollection:v.traitCollection];
    CGFloat r, g, b, a;
    if (!ApolloBBColorRGBA(resolved, &r, &g, &b, &a)) return nil;
    return (a > 0.85) ? bg : nil;
}

// Nearest opaque background painted around `seed`. List screens usually carry
// the themed canvas on a scroll view one or two levels down, so check those
// first, then walk up the superview chain.
static UIColor *ApolloBBSampledBackground(UIView *seed) {
    if (!seed) return nil;
    for (UIView *sub in seed.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]) { UIColor *c = ApolloBBOpaqueBackgroundOf(sub); if (c) return c; }
        for (UIView *sub2 in sub.subviews) {
            if ([sub2 isKindOfClass:[UIScrollView class]]) { UIColor *c = ApolloBBOpaqueBackgroundOf(sub2); if (c) return c; }
        }
    }
    for (UIView *v = seed; v; v = v.superview) {
        UIColor *c = ApolloBBOpaqueBackgroundOf(v);
        if (c) return c;
    }
    return nil;
}

// A slightly-elevated surface variant of a background (cards, chips): dark
// backgrounds step toward white, light ones toward black — harmonizes with any
// sampled theme without knowing its palette. Dynamic so trait flips re-derive.
static UIColor *ApolloBBElevatedColor(UIColor *base) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        UIColor *resolved = [base resolvedColorWithTraitCollection:traits];
        CGFloat r, g, b, a;
        if (!ApolloBBColorRGBA(resolved, &r, &g, &b, &a)) return resolved;
        CGFloat lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        CGFloat target = (lum < 0.5) ? 1.0 : 0.0;
        CGFloat amount = (lum < 0.5) ? 0.10 : 0.055;
        return [UIColor colorWithRed:r + (target - r) * amount
                               green:g + (target - g) * amount
                                blue:b + (target - b) * amount
                               alpha:1.0];
    }];
}

#pragma mark - Placeholder circle

// The unearned-badge placeholder: a plain filled circle with an inner shadow for
// depth (a lock glyph sits on top as a separate view). Rendered once per fill
// color and cached — every locked cell blits the same bitmap.
static UIImage *ApolloBBPlaceholderCircleImage(UIColor *fill, UITraitCollection *traits) {
    UIColor *resolved = traits ? [fill resolvedColorWithTraitCollection:traits] : fill;
    CGFloat r = 0.5, g = 0.5, b = 0.5, a = 1.0;
    ApolloBBColorRGBA(resolved, &r, &g, &b, &a);
    NSString *key = [NSString stringWithFormat:@"%.3f-%.3f-%.3f", r, g, b];

    static NSCache<NSString *, UIImage *> *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 12; });
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;

    CGFloat const S = 132.0;   // largest display size (detail card); grid scales down
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(S, S) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect oval = CGRectInset(CGRectMake(0.0, 0.0, S, S), 1.0, 1.0);
        UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:oval];
        [[UIColor colorWithRed:r green:g blue:b alpha:1.0] setFill];
        [circle fill];

        // Inner shadow: clip to the circle, then fill everything OUTSIDE it with
        // a shadow — only the shadow lands inside the clip, hugging the edge.
        CGContextSaveGState(c);
        [circle addClip];
        UIBezierPath *outside = [UIBezierPath bezierPathWithRect:CGRectInset(CGRectMake(0.0, 0.0, S, S), -30.0, -30.0)];
        [outside appendPath:circle];
        outside.usesEvenOddFillRule = YES;
        CGContextSetShadowWithColor(c, CGSizeMake(0.0, 4.0), 10.0, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
        [[UIColor blackColor] setFill];
        [outside fill];
        CGContextRestoreGState(c);
    }];
    [cache setObject:image forKey:key];
    return image;
}

#pragma mark - Cell

// Two lines of caption2 at the CURRENT content size category. Hardcoding this
// clipped every title in the grid at accessibility text sizes, so both the label
// and the cell height (sizeForItemAtIndexPath) derive from it.
static CGFloat ApolloBBTitleHeight(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    return ceil(font.lineHeight * 2.0) + 2.0;
}

@interface ApolloBadgeCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIImageView *statusBadge;   // corner check chip (earned only)
@property(nonatomic, strong) UIImageView *lockGlyph;     // centered lock (locked only)
@property(nonatomic, copy) NSString *loadingImageKey;    // guards async completions on reused cells
// Theme colors, set by the VC before applyItem.
@property(nonatomic, strong) UIColor *chipBackgroundColor;     // ring behind the check
@property(nonatomic, strong) UIColor *placeholderFillColor;    // locked-circle fill
- (void)applyItem:(ApolloBadgeItem *)item state:(ApolloBadgeState)state accent:(UIColor *)accent artURL:(NSString *)artURL;
@end

@implementation ApolloBadgeCell {
    // Last-applied inputs, replayed on an appearance change (see below).
    ApolloBadgeItem *_appliedItem;
    ApolloBadgeState _appliedState;
    UIColor *_appliedAccent;
    NSString *_appliedArtURL;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.clipsToBounds = NO;
        [self.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 2;
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_titleLabel];

        _lockGlyph = [[UIImageView alloc] init];
        _lockGlyph.contentMode = UIViewContentModeScaleAspectFit;
        _lockGlyph.image = [UIImage systemImageNamed:@"lock.fill"];
        _lockGlyph.tintColor = [UIColor secondaryLabelColor];
        _lockGlyph.hidden = YES;
        [self.contentView addSubview:_lockGlyph];

        _statusBadge = [[UIImageView alloc] init];
        _statusBadge.contentMode = UIViewContentModeScaleAspectFit;
        _statusBadge.hidden = YES;
        [self.contentView addSubview:_statusBadge];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat labelH = ApolloBBTitleHeight();
    CGFloat iconBox = MAX(0.0, MIN(w, h - labelH - 4.0));
    CGFloat iconX = (w - iconBox) / 2.0;
    self.iconView.frame = CGRectMake(iconX, 0.0, iconBox, iconBox);
    self.titleLabel.frame = CGRectMake(0.0, CGRectGetMaxY(self.iconView.frame) + 4.0, w, labelH);

    CGFloat lock = MAX(16.0, iconBox * 0.26);
    self.lockGlyph.frame = CGRectMake(iconX + (iconBox - lock) / 2.0,
                                      (iconBox - lock) / 2.0, lock, lock);

    CGFloat badge = 20.0;
    self.statusBadge.frame = CGRectMake(CGRectGetMaxX(self.iconView.frame) - badge + 2.0,
                                        CGRectGetMaxY(self.iconView.frame) - badge + 2.0, badge, badge);
}

- (void)applyItem:(ApolloBadgeItem *)item state:(ApolloBadgeState)state accent:(UIColor *)accent artURL:(NSString *)artURL {
    // Remembered so a light/dark flip can re-render the (rasterized, non-dynamic)
    // placeholder circle without waiting for the cell to be recycled.
    _appliedItem = item;
    _appliedState = state;
    _appliedAccent = accent;
    _appliedArtURL = [artURL copy];

    self.titleLabel.text = item.title;
    BOOL locked = (state == ApolloBadgeStateLocked);
    UIImage *placeholder = ApolloBBPlaceholderCircleImage(self.placeholderFillColor ?: [UIColor secondarySystemFillColor],
                                                          self.traitCollection);

    // For achievements the catalogue image_url may be Reddit's near-invisible
    // "ghost" placeholder — only the per-user art URL from the achievements
    // page is trustworthy. Trophies' scraped/API URLs are always real art.
    NSString *remote = artURL.length ? artURL
        : (item.kind == ApolloBadgeKindTrophy ? item.imageURLString : nil);

    if (locked) {
        self.iconView.image = placeholder;
        self.lockGlyph.hidden = NO;
        self.loadingImageKey = nil;
    } else {
        self.lockGlyph.hidden = YES;
        UIImage *warm = [item cachedBundledImage];
        if (warm) {
            self.iconView.image = warm;
            self.loadingImageKey = nil;
        } else if (item.imageFile.length) {
            // Cold cache (prewarm still running, or an evicted entry): decode off
            // the main thread rather than stalling this scroll frame on file I/O.
            self.iconView.image = placeholder;   // never a blank tile while loading
            NSString *key = [@"bundled:" stringByAppendingString:item.imageFile];
            self.loadingImageKey = key;
            __weak typeof(self) ws = self;
            [item loadBundledImage:^(UIImage *image) {
                typeof(self) ss = ws; if (!ss) return;
                if (![ss.loadingImageKey isEqualToString:key]) return;  // cell reused
                if (image) { ss.iconView.image = image; ss.loadingImageKey = nil; return; }
                // Bundled file missing — fall through to the remote art if any.
                if (remote.length) [ss apollo_loadRemoteArt:remote];
            }];
        } else if (remote.length) {
            self.iconView.image = placeholder;
            [self apollo_loadRemoteArt:remote];
        } else {
            self.iconView.image = placeholder;
            self.loadingImageKey = nil;
        }
    }

    self.titleLabel.alpha = locked ? 0.55 : 1.0;

    if (state == ApolloBadgeStateEarned) {
        self.statusBadge.hidden = NO;
        self.statusBadge.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        self.statusBadge.tintColor = accent;
        // Keep the check legible on any badge art; the ring matches the screen
        // background so it reads as a cutout.
        self.statusBadge.backgroundColor = self.chipBackgroundColor ?: [UIColor systemBackgroundColor];
        self.statusBadge.layer.cornerRadius = 10.0;
        self.statusBadge.clipsToBounds = YES;
    } else {
        self.statusBadge.hidden = YES;
    }
}

- (void)apollo_loadRemoteArt:(NSString *)remote {
    NSString *key = remote;
    self.loadingImageKey = key;
    __weak typeof(self) ws = self;
    ApolloBBLoadRemoteImage(key, 64.0, ^(UIImage *image) {
        typeof(self) ss = ws; if (!ss || !image) return;
        if (![ss.loadingImageKey isEqualToString:key]) return;  // cell reused
        ss.iconView.image = image;
    });
}

// The placeholder circle is a bitmap baked from a resolved fill color, so unlike
// every semantic-colored label around it, it does NOT follow a live appearance
// change. Re-apply the cell to regenerate it at the new appearance.
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!_appliedItem) return;
    if (![self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) return;
    [self applyItem:_appliedItem state:_appliedState accent:_appliedAccent artURL:_appliedArtURL];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.titleLabel.alpha = 1.0;
    self.statusBadge.hidden = YES;
    self.lockGlyph.hidden = YES;
    self.loadingImageKey = nil;
    _appliedItem = nil;
    _appliedArtURL = nil;
}

@end

#pragma mark - Section header

// Same reasoning as ApolloBBTitleHeight: a fixed 42pt header truncated the
// category name at large text sizes.
static CGFloat ApolloBBHeaderHeight(void) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    return MAX(42.0, ceil(font.lineHeight) + 16.0);
}

@interface ApolloBadgeSectionHeader : UICollectionReusableView
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *countLabel;
@end

@implementation ApolloBadgeSectionHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textColor = [UIColor labelColor];
        [self addSubview:_titleLabel];

        _countLabel = [[UILabel alloc] init];
        _countLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _countLabel.adjustsFontForContentSizeCategory = YES;
        _countLabel.textColor = [UIColor secondaryLabelColor];
        _countLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_countLabel];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = 16.0;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    // Only as wide as the count actually needs, so the category name keeps the rest.
    CGFloat countW = MIN(ceil([self.countLabel sizeThatFits:CGSizeMake(w, h)].width) + 4.0, floor(w * 0.45));
    self.titleLabel.frame = CGRectMake(inset, 0.0, w - inset * 2.0 - countW, self.bounds.size.height);
    self.countLabel.frame = CGRectMake(w - inset - countW, 0.0, countW, self.bounds.size.height);
}
@end

#pragma mark - Detail sheet ("holo card")

// The detail presentation is a collectible-card: the badge sits on a tilting card
// with a rotating iridescent ring and a periodic specular shine sweep — all
// Core-Animation-composited (GPU), no per-frame main-thread work. On iOS 26
// Liquid Glass builds the card itself is real glass (UIGlassEffect); elsewhere a
// theme-derived surface. Earned badges get a sparkle burst on reveal; locked
// ones present the placeholder circle + lock. Tilt comes from a pan gesture
// everywhere, plus device motion when available (real hardware).
@interface ApolloBadgeDetailViewController : UIViewController
- (instancetype)initWithItem:(ApolloBadgeItem *)item state:(ApolloBadgeState)state accent:(UIColor *)accent
                  background:(UIColor *)background surface:(UIColor *)surface artURL:(NSString *)artURL
                    username:(NSString *)username;
@end

@implementation ApolloBadgeDetailViewController {
    ApolloBadgeItem *_item;
    ApolloBadgeState _state;
    UIColor *_accent;
    UIColor *_background;
    UIColor *_surface;
    NSString *_artURL;
    NSString *_username;          // whose book this badge came from (locked copy)
    UIView *_card;
    UIView *_shineHost;          // clips the moving shine to the card
    CAGradientLayer *_shine;
    CAGradientLayer *_holoRing;
    UIImageView *_iconView;
    CAEmitterLayer *_sparkles;
    CMMotionManager *_motion;
    BOOL _panActive;
    BOOL _iconShowsPlaceholder;   // placeholder circle is a bitmap; regenerate on appearance flips
}

// Apple asks for ONE CMMotionManager per app — each instance stands up its own
// sensor session. Tapping in and out of a few cards was tearing down and
// re-creating a full 60Hz device-motion session every time, purely for a
// decorative tilt. One shared, lazily-created manager instead.
static CMMotionManager *ApolloBBSharedMotionManager(void) {
    static CMMotionManager *shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CMMotionManager alloc] init]; });
    return shared;
}

- (instancetype)initWithItem:(ApolloBadgeItem *)item state:(ApolloBadgeState)state accent:(UIColor *)accent
                  background:(UIColor *)background surface:(UIColor *)surface artURL:(NSString *)artURL
                    username:(NSString *)username {
    if ((self = [super init])) {
        _item = item; _state = state; _accent = accent;
        _background = background; _surface = surface; _artURL = [artURL copy];
        _username = [username copy];
    }
    return self;
}

- (BOOL)apollo_isEarnedLook {
    return _item.kind == ApolloBadgeKindTrophy || _state == ApolloBadgeStateEarned;
}

// The accent is a dynamic-provider color. Anything that bakes it into a CGColor
// (the holo ring's gradient, the sparkle emitter cell) must resolve it against
// real in-hierarchy traits first — ambient resolution picks the wrong light/dark
// variant whenever Apollo's theme overrides the window style.
- (UIColor *)apollo_resolvedAccent {
    UIColor *accent = _accent ?: [UIColor systemBlueColor];
    UITraitCollection *traits = (_card.window ? _card.traitCollection : self.view.traitCollection);
    return traits ? [accent resolvedColorWithTraitCollection:traits] : accent;
}

// Ring colors are CGColors, so they don't follow a live appearance change on
// their own — re-derived from viewDidLoad, viewDidAppear (card in the window by
// then) and any subsequent trait flip.
- (void)apollo_applyHoloRingColors {
    if (!_holoRing) return;
    UIColor *accent = [self apollo_resolvedAccent];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _holoRing.colors = @[
        (id)accent.CGColor,
        (id)[UIColor systemTealColor].CGColor,
        (id)[UIColor systemPurpleColor].CGColor,
        (id)[UIColor systemPinkColor].CGColor,
        (id)[UIColor systemOrangeColor].CGColor,
        (id)[UIColor systemYellowColor].CGColor,
        (id)accent.CGColor,
    ];
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) return;
    [self apollo_applyHoloRingColors];
    // Same story as the grid cell: the placeholder circle is a baked bitmap.
    if (_iconShowsPlaceholder) {
        _iconView.image = ApolloBBPlaceholderCircleImage(ApolloBBElevatedColor(_surface ?: [UIColor secondarySystemGroupedBackgroundColor]),
                                                         self.view.traitCollection);
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Backgrounding strips the infinite ring/shine CAAnimations; re-install on
    // foreground (see apollo_appWillEnterForeground).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    UIColor *background = _background ?: [UIColor systemGroupedBackgroundColor];
    UIColor *surface = _surface ?: [UIColor secondarySystemGroupedBackgroundColor];
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    BOOL useGlass = IsLiquidGlass() && glassClass != nil;
    // On Liquid Glass builds the sheet supplies its own glass drawer material —
    // painting an opaque background over it would flatten the whole presentation.
    self.view.backgroundColor = useGlass ? [UIColor clearColor] : background;
    BOOL locked = (_state == ApolloBadgeStateLocked);
    BOOL earnedLook = [self apollo_isEarnedLook];

    // ---- Card (Liquid Glass when the app runs the iOS 26 design) ----
    UIView *card = [[UIView alloc] init];
    _card = card;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowRadius = 18.0;
    card.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    if (useGlass) {
        card.backgroundColor = [UIColor clearColor];
        card.layer.shadowOpacity = 0.10;
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[[glassClass alloc] init]];
        glass.frame = card.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = 26.0;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
        glass.userInteractionEnabled = NO;
        [card addSubview:glass];
    } else {
        card.backgroundColor = surface;
        card.layer.shadowOpacity = 0.22;
    }
    [self.view addSubview:card];

    // ---- Holo ring (earned/trophy): rotating iridescent conic gradient masked
    // to a ring behind the icon ----
    UIView *ringHost = [[UIView alloc] init];
    ringHost.translatesAutoresizingMaskIntoConstraints = NO;
    ringHost.userInteractionEnabled = NO;
    [card addSubview:ringHost];
    CGFloat const kRingSize = 168.0;
    if (earnedLook) {
        CAGradientLayer *ring = [CAGradientLayer layer];
        ring.type = kCAGradientLayerConic;
        ring.frame = CGRectMake(0.0, 0.0, kRingSize, kRingSize);
        ring.startPoint = CGPointMake(0.5, 0.5);
        ring.endPoint = CGPointMake(1.0, 0.5);
        CAShapeLayer *ringMask = [CAShapeLayer layer];
        CGFloat inset = 5.0;
        ringMask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ring.bounds, inset, inset)].CGPath;
        ringMask.fillColor = [UIColor clearColor].CGColor;
        ringMask.strokeColor = [UIColor whiteColor].CGColor;
        ringMask.lineWidth = 9.0;
        ring.mask = ringMask;
        [ringHost.layer addSublayer:ring];
        _holoRing = ring;
        [self apollo_applyHoloRingColors];

        [self apollo_startHoloSpin];
    }

    // ---- Icon ----
    UIImageView *icon = [[UIImageView alloc] init];
    _iconView = icon;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *placeholder = ApolloBBPlaceholderCircleImage(ApolloBBElevatedColor(surface), self.view.traitCollection);
    UIImageView *lockGlyph = nil;
    if (locked) {
        icon.image = placeholder;
        _iconShowsPlaceholder = YES;
        lockGlyph = [[UIImageView alloc] init];
        lockGlyph.contentMode = UIViewContentModeScaleAspectFit;
        lockGlyph.image = [UIImage systemImageNamed:@"lock.fill"];
        lockGlyph.tintColor = [UIColor secondaryLabelColor];
        lockGlyph.translatesAutoresizingMaskIntoConstraints = NO;
    } else {
        UIImage *warm = [_item cachedBundledImage];
        NSString *remote = _artURL.length ? _artURL
            : (_item.kind == ApolloBadgeKindTrophy ? _item.imageURLString : nil);
        if (warm) {
            icon.image = warm;
        } else if (_item.imageFile.length) {
            // Cold cache: decode off-main rather than blocking the push animation.
            icon.image = placeholder;
            _iconShowsPlaceholder = YES;
            __weak typeof(self) ws = self;
            [_item loadBundledImage:^(UIImage *image) {
                typeof(self) ss = ws; if (!ss) return;
                if (image) { icon.image = image; ss->_iconShowsPlaceholder = NO; return; }
                if (remote.length) {
                    ApolloBBLoadRemoteImage(remote, 140.0, ^(UIImage *art) {
                        typeof(self) ss2 = ws; if (!ss2 || !art) return;
                        icon.image = art; ss2->_iconShowsPlaceholder = NO;
                    });
                }
            }];
        } else if (remote.length) {
            icon.image = placeholder;
            _iconShowsPlaceholder = YES;
            __weak typeof(self) ws = self;
            ApolloBBLoadRemoteImage(remote, 140.0, ^(UIImage *image) {
                typeof(self) ss = ws; if (!ss || !image) return;
                icon.image = image; ss->_iconShowsPlaceholder = NO;
            });
        } else {
            icon.image = placeholder;
            _iconShowsPlaceholder = YES;
        }
    }
    [card addSubview:icon];
    if (lockGlyph) [card addSubview:lockGlyph];   // above the placeholder circle

    // ---- Text stack ----
    UILabel *title = [[UILabel alloc] init];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 0;
    title.textAlignment = NSTextAlignmentCenter;
    title.text = _item.title;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    // Status pill: a real padded container (a bare padded-with-spaces label never
    // centers its text correctly).
    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.layer.cornerRadius = 13.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    UILabel *pillLabel = [[UILabel alloc] init];
    pillLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    pillLabel.adjustsFontForContentSizeCategory = YES;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:pillLabel];
    UIColor *accent = _accent ?: [UIColor systemBlueColor];
    BOOL accentIsLight = ApolloColorIsLight(accent);
    if (_item.kind == ApolloBadgeKindTrophy) {
        pillLabel.text = @"Trophy";
        pillLabel.textColor = accentIsLight ? [UIColor blackColor] : [UIColor whiteColor];
        pill.backgroundColor = accent;
    } else if (_state == ApolloBadgeStateEarned) {
        pillLabel.text = @"Earned";
        pillLabel.textColor = accentIsLight ? [UIColor blackColor] : [UIColor whiteColor];
        pill.backgroundColor = accent;
    } else if (locked) {
        pillLabel.text = @"Locked";
        pillLabel.textColor = [UIColor labelColor];
        pill.backgroundColor = [UIColor tertiarySystemFillColor];
    } else {
        pill.hidden = YES;
    }
    [card addSubview:pill];

    // Locked: say it plainly.
    UILabel *lockedNote = nil;
    if (locked) {
        lockedNote = [[UILabel alloc] init];
        lockedNote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        lockedNote.adjustsFontForContentSizeCategory = YES;
        lockedNote.numberOfLines = 0;
        lockedNote.textAlignment = NSTextAlignmentCenter;
        lockedNote.textColor = [UIColor secondaryLabelColor];
        // The book opens for anyone's profile, and locked state is the VIEWED
        // user's — "You" is only right when that's the signed-in account.
        NSString *activeUser = ApolloActiveAccountUsername();
        BOOL viewingOwn = (_username.length && activeUser.length &&
                           [activeUser caseInsensitiveCompare:_username] == NSOrderedSame);
        if (viewingOwn) {
            lockedNote.text = @"You haven't earned this badge yet.";
        } else if (_username.length) {
            lockedNote.text = [NSString stringWithFormat:@"u/%@ hasn't earned this badge yet.", _username];
        } else {
            lockedNote.text = @"This badge hasn't been earned yet.";
        }
        lockedNote.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:lockedNote];
    }

    UILabel *bio = [[UILabel alloc] init];
    bio.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    bio.adjustsFontForContentSizeCategory = YES;
    bio.numberOfLines = 0;
    bio.textAlignment = NSTextAlignmentCenter;
    bio.textColor = locked ? [UIColor tertiaryLabelColor] : [UIColor secondaryLabelColor];
    bio.text = _item.bio.length ? _item.bio : @"";
    bio.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:bio];

    UIButton *open = nil;
    if (_item.kind == ApolloBadgeKindTrophy && _item.destinationURLString.length) {
        open = [UIButton buttonWithType:UIButtonTypeSystem];
        [open setTitle:@"Open in Reddit" forState:UIControlStateNormal];
        open.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        open.tintColor = accent;
        open.translatesAutoresizingMaskIntoConstraints = NO;
        [open addTarget:self action:@selector(apollo_openDestination) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:open];
    }

    // ---- Shine sweep host (masks the moving gradient to the card bounds) ----
    UIView *shineHost = [[UIView alloc] init];
    _shineHost = shineHost;
    shineHost.translatesAutoresizingMaskIntoConstraints = NO;
    shineHost.userInteractionEnabled = NO;
    shineHost.layer.cornerRadius = 26.0;
    shineHost.layer.cornerCurve = kCACornerCurveContinuous;
    shineHost.layer.masksToBounds = YES;
    [card addSubview:shineHost];

    // ---- Constraints ----
    UILayoutGuide *g = self.view.layoutMarginsGuide;
    NSLayoutConstraint *cardWidth = [card.widthAnchor constraintEqualToAnchor:g.widthAnchor];
    cardWidth.priority = UILayoutPriorityDefaultHigh;   // yields to the 360pt cap on wide screens
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [card.topAnchor constraintEqualToAnchor:g.topAnchor constant:18.0],
        [card.widthAnchor constraintLessThanOrEqualToConstant:360.0],
        [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:g.leadingAnchor],
        [card.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor],
        cardWidth,

        [ringHost.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [ringHost.topAnchor constraintEqualToAnchor:card.topAnchor constant:26.0],
        [ringHost.widthAnchor constraintEqualToConstant:kRingSize],
        [ringHost.heightAnchor constraintEqualToConstant:kRingSize],

        [icon.centerXAnchor constraintEqualToAnchor:ringHost.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:ringHost.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:132.0],
        [icon.heightAnchor constraintEqualToConstant:132.0],

        [title.topAnchor constraintEqualToAnchor:ringHost.bottomAnchor constant:14.0],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [pill.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [pill.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [pillLabel.topAnchor constraintEqualToAnchor:pill.topAnchor constant:5.0],
        [pillLabel.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-5.0],
        [pillLabel.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12.0],
        [pillLabel.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12.0],

        [bio.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
        [bio.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],

        [shineHost.topAnchor constraintEqualToAnchor:card.topAnchor],
        [shineHost.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [shineHost.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [shineHost.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    if (lockGlyph) {
        [NSLayoutConstraint activateConstraints:@[
            [lockGlyph.centerXAnchor constraintEqualToAnchor:icon.centerXAnchor],
            [lockGlyph.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
            [lockGlyph.widthAnchor constraintEqualToConstant:38.0],
            [lockGlyph.heightAnchor constraintEqualToConstant:38.0],
        ]];
    }
    if (lockedNote) {
        [NSLayoutConstraint activateConstraints:@[
            [lockedNote.topAnchor constraintEqualToAnchor:pill.bottomAnchor constant:12.0],
            [lockedNote.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20.0],
            [lockedNote.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20.0],
            [bio.topAnchor constraintEqualToAnchor:lockedNote.bottomAnchor constant:10.0],
        ]];
    } else {
        [[bio.topAnchor constraintEqualToAnchor:pill.bottomAnchor constant:14.0] setActive:YES];
    }
    if (open) {
        [NSLayoutConstraint activateConstraints:@[
            [open.topAnchor constraintEqualToAnchor:bio.bottomAnchor constant:14.0],
            [open.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [card.bottomAnchor constraintEqualToAnchor:open.bottomAnchor constant:20.0],
        ]];
    } else {
        [[card.bottomAnchor constraintEqualToAnchor:bio.bottomAnchor constant:24.0] setActive:YES];
    }

    // ---- Tilt: pan-driven everywhere (motion joins in on hardware) ----
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_cardPanned:)];
    [card addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Explicit shadow path: the glass card has no opaque background for UIKit to
    // derive one from (and it skips an offscreen pass either way).
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:26.0].CGPath;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self apollo_applyHoloRingColors];   // card is in the window now — real traits
    [self apollo_installShine];
    if ([self apollo_isEarnedLook]) [self apollo_burstSparkles];
    [self apollo_startMotionTilt];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_motion stopDeviceMotionUpdates];
    _motion = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// A soft diagonal white band swept across the card every few seconds.
- (void)apollo_installShine {
    if (_shine || _shineHost.bounds.size.width <= 0.0) return;
    CGRect bounds = _shineHost.bounds;
    CAGradientLayer *shine = [CAGradientLayer layer];
    shine.frame = CGRectMake(0.0, 0.0, bounds.size.width * 0.55, bounds.size.height * 1.8);
    BOOL earnedLook = [self apollo_isEarnedLook];
    CGFloat peak = earnedLook ? 0.20 : 0.07;
    shine.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:peak].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
    ];
    shine.startPoint = CGPointMake(0.0, 0.5);
    shine.endPoint = CGPointMake(1.0, 0.5);
    shine.transform = CATransform3DMakeRotation(0.35, 0.0, 0.0, 1.0);
    shine.position = CGPointMake(-bounds.size.width * 0.6, bounds.size.height / 2.0);
    [_shineHost.layer addSublayer:shine];
    _shine = shine;
    [self apollo_startShineSweep];
}

// Both infinite decorations live here so the foreground handler can re-install
// them: the system strips CAAnimations from every layer when the app
// backgrounds, and nothing else re-runs (viewDidAppear doesn't fire on
// foreground) — without this the ring freezes mid-rotation and the shine
// parks offscreen for the card's remaining lifetime.
- (void)apollo_startHoloSpin {
    if (!_holoRing || [_holoRing animationForKey:@"holoSpin"]) return;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0.0;
    spin.toValue = @(2.0 * M_PI);
    spin.duration = 6.0;
    spin.repeatCount = HUGE_VALF;
    [_holoRing addAnimation:spin forKey:@"holoSpin"];
}

- (void)apollo_startShineSweep {
    if (!_shine || [_shine animationForKey:@"sweep"]) return;
    CGRect bounds = _shineHost.bounds;
    CAKeyframeAnimation *sweep = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    sweep.values = @[@(-bounds.size.width * 0.6), @(bounds.size.width * 1.6), @(bounds.size.width * 1.6)];
    sweep.keyTimes = @[@0.0, @0.42, @1.0];   // sweep, then rest — feels like light catching
    sweep.duration = 4.2;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    [_shine addAnimation:sweep forKey:@"sweep"];
}

- (void)apollo_appWillEnterForeground {
    [self apollo_startHoloSpin];
    [self apollo_startShineSweep];
}

// One-shot celebratory burst from behind the icon.
- (void)apollo_burstSparkles {
    if (_sparkles) return;
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    CGPoint center = [_card convertPoint:_iconView.center fromView:_iconView.superview];
    emitter.emitterPosition = center;
    emitter.emitterShape = kCAEmitterLayerPoint;
    emitter.beginTime = CACurrentMediaTime();

    // Tiny glowing dot drawn in code — no asset needed.
    CGFloat dot = 12.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(dot, dot)];
    UIImage *spark = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2.0, 2.0, dot - 4.0, dot - 4.0)] fill];
    }];

    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (id)spark.CGImage;
    cell.birthRate = 260.0;
    cell.lifetime = 1.15;
    cell.velocity = 120.0;
    cell.velocityRange = 70.0;
    cell.emissionRange = 2.0 * M_PI;
    cell.scale = 0.35;
    cell.scaleRange = 0.25;
    cell.scaleSpeed = -0.25;
    cell.alphaSpeed = -1.0;
    cell.spin = 2.0;
    cell.spinRange = 4.0;
    cell.color = [[self apollo_resolvedAccent] colorWithAlphaComponent:0.95].CGColor;
    emitter.emitterCells = @[cell];
    [_card.layer addSublayer:emitter];
    _sparkles = emitter;

    // Burst, then stop feeding — live particles finish their lifetime.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        emitter.birthRate = 0.0;
    });
}

#pragma mark Tilt

- (void)apollo_applyTiltX:(CGFloat)rx y:(CGFloat)ry {
    // rx/ry in radians, clamped small; perspective makes it read as a real card.
    CGFloat const maxTilt = 0.22;
    rx = MAX(-maxTilt, MIN(maxTilt, rx));
    ry = MAX(-maxTilt, MIN(maxTilt, ry));
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / 600.0;
    t = CATransform3DRotate(t, rx, 1.0, 0.0, 0.0);
    t = CATransform3DRotate(t, ry, 0.0, 1.0, 0.0);
    _card.layer.transform = t;
    // Parallax: the shine drifts opposite the tilt, like light on foil.
    if (_shine) {
        CATransform3D s = CATransform3DMakeRotation(0.35, 0.0, 0.0, 1.0);
        s = CATransform3DTranslate(s, ry * 220.0, rx * 160.0, 0.0);
        // _shine is a bare sublayer (not view-backed) — without this every
        // 30Hz write spawns a 0.25s implicit animation: transaction churn and
        // the parallax visibly lags its input by the implicit duration.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _shine.transform = s;
        [CATransaction commit];
    }
}

- (void)apollo_cardPanned:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _panActive = YES;
            // fallthrough
        case UIGestureRecognizerStateChanged: {
            CGPoint tr = [pan translationInView:_card];
            [self apollo_applyTiltX:(-tr.y / 420.0) y:(tr.x / 420.0)];
            break;
        }
        default: {
            // _panActive stays YES until the spring settles — the 30Hz motion
            // handler writes layer.transform directly, which would clobber the
            // in-flight animation (card snaps to the motion pose mid-spring).
            [UIView animateWithDuration:0.6 delay:0.0
                 usingSpringWithDamping:0.45 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{ self->_card.layer.transform = CATransform3DIdentity; }
                             completion:^(BOOL finished) {
                self->_panActive = NO;
                // Restart with a fresh attitude baseline so the first
                // post-settle tick starts from the card's current (identity)
                // pose instead of snapping to the stale pre-pan reference.
                if (self->_motion) [self apollo_startMotionTilt];
            }];
            break;
        }
    }
}

- (void)apollo_startMotionTilt {
    CMMotionManager *motion = ApolloBBSharedMotionManager();
    if (!motion.isDeviceMotionAvailable) return;   // simulator / no sensors
    // Hand the shared session to whichever card is on screen now.
    if (motion.isDeviceMotionActive) [motion stopDeviceMotionUpdates];
    _motion = motion;
    // 30Hz is plenty for a card that only ever rotates a few degrees, and halves
    // the sensor callbacks versus the old 60Hz.
    motion.deviceMotionUpdateInterval = 1.0 / 30.0;
    __weak typeof(self) ws = self;
    __block BOOL hasBase = NO;
    __block double baseRoll = 0.0, basePitch = 0.0;
    [motion startDeviceMotionUpdatesToQueue:[NSOperationQueue mainQueue]
                                withHandler:^(CMDeviceMotion *dm, NSError *error) {
        typeof(self) ss = ws;
        if (!ss || !dm || ss->_panActive) return;
        if (!hasBase) { baseRoll = dm.attitude.roll; basePitch = dm.attitude.pitch; hasBase = YES; }
        [ss apollo_applyTiltX:(dm.attitude.pitch - basePitch) * 0.5
                            y:(dm.attitude.roll - baseRoll) * 0.5];
    }];
}

- (void)apollo_openDestination {
    NSURL *url = [NSURL URLWithString:_item.destinationURLString];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Badge Book

typedef NS_ENUM(NSInteger, ApolloBadgeBookMode) {
    ApolloBadgeBookModeAchievements = 0,
    ApolloBadgeBookModeTrophies = 1,
};

@interface ApolloBadgeBookViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property(nonatomic, copy, readwrite) NSString *username;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UISegmentedControl *segmented;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) ApolloBadgeBookCatalog *catalog;
@property(nonatomic, strong) ApolloUserBadges *userBadges;   // nil until scrape resolves
@property(nonatomic) BOOL fetchFailed;                       // scrape hard-failed (result nil)
@property(nonatomic) ApolloBadgeBookMode mode;
// Ambient theme, captured from the presenting hierarchy at push time.
@property(nonatomic, strong) UIColor *themeBackground;
@property(nonatomic, strong) UIColor *themeSurface;
- (void)apollo_captureThemeFromView:(UIView *)context;
- (void)apollo_modeChanged;
@end

@implementation ApolloBadgeBookViewController

static NSString *const kCellID = @"badge";
static NSString *const kHeaderID = @"header";

- (instancetype)initWithUsername:(NSString *)username {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _username = [username copy];
        _catalog = [ApolloBadgeBookCatalog shared];
    }
    return self;
}

- (void)apollo_captureThemeFromView:(UIView *)context {
    UIColor *tokenBackground = ApolloThemeRuntimeColor(ApolloThemeTokenBackground);
    UIColor *tokenSurface = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground);
    UIColor *sampled = tokenBackground ?: ApolloBBSampledBackground(context);
    self.themeBackground = sampled ?: [UIColor systemGroupedBackgroundColor];
    self.themeSurface = tokenSurface
        ?: (sampled ? ApolloBBElevatedColor(sampled) : [UIColor secondarySystemGroupedBackgroundColor]);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.themeBackground) [self apollo_captureThemeFromView:self.view];
    self.view.backgroundColor = self.themeBackground;
    ApolloBadgeBookPrewarmImages();

    UIColor *accent = ApolloBBAccent(self.view);
    self.segmented = [[UISegmentedControl alloc] initWithItems:@[@"Achievements", @"Trophy Case"]];
    self.segmented.selectedSegmentIndex = 0;
    self.segmented.tintColor = accent;
    if (@available(iOS 13.0, *)) {
        self.segmented.selectedSegmentTintColor = accent;
        UIColor *selectedText = ApolloColorIsLight(accent) ? [UIColor blackColor] : [UIColor whiteColor];
        [self.segmented setTitleTextAttributes:@{ NSForegroundColorAttributeName: selectedText }
                                      forState:UIControlStateSelected];
    }
    [self.segmented addTarget:self action:@selector(apollo_modeChanged) forControlEvents:UIControlEventValueChanged];
    if (IsLiquidGlass()) {
        // The Liquid Glass nav bar wraps an INTERACTIVE (UIControl) titleView in
        // its own padded glass platter capsule — and an iOS 26 UISegmentedControl
        // already draws its own glass track, so the two nest as a "double glass"
        // outline (reported on-device, #689). Hosting the control inside a plain
        // non-control container opts out of the platter while keeping the
        // control's own glass; a UIStackView forwards the intrinsic size the bar
        // needs (a bare UIView wrapper collapses to zero and vanishes). Verified
        // in the glass sim: platter alone gone, and the selected segment regains
        // the accent tint the platter glass was muting.
        UIStackView *host = [[UIStackView alloc] initWithArrangedSubviews:@[self.segmented]];
        self.navigationItem.titleView = host;
    } else {
        self.navigationItem.titleView = self.segmented;
    }

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(12.0, 16.0, 24.0, 16.0);
    layout.minimumInteritemSpacing = 10.0;
    layout.minimumLineSpacing = 14.0;
    layout.headerReferenceSize = CGSizeMake(0.0, ApolloBBHeaderHeight());

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[ApolloBadgeCell class] forCellWithReuseIdentifier:kCellID];
    [self.collectionView registerClass:[ApolloBadgeSectionHeader class]
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:kHeaderID];
    [self.view addSubview:self.collectionView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.color = [UIColor secondaryLabelColor];
    [self.view addSubview:self.spinner];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(apollo_pullToRefresh:) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = refresh;

    // The two scrape legs land independently (trophies + achievements) — refresh live.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(apollo_userBadgesUpdated:)
                                                 name:ApolloBadgeBookUserUpdatedNotification object:nil];

    [self apollo_startFetch];
    [self apollo_updateLoadingUI];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)apollo_userBadgesUpdated:(NSNotification *)note {
    NSString *user = [note.object isKindOfClass:[NSString class]] ? note.object : nil;
    if (![user.lowercaseString isEqualToString:self.username.lowercaseString]) return;
    [self apollo_startFetch];   // warm cache → synchronous updated result
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Cell height is derived from the current text size, so the flow layout has to
    // re-measure when the user changes it while the book is on screen.
    if (![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
    self.emptyLabel.frame = CGRectInset(self.view.bounds, 40.0, 0.0);
    self.emptyLabel.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
}

- (void)apollo_startFetch {
    __weak typeof(self) ws = self;
    NSString *user = self.username;
    ApolloBadgeBookFetch(user, ^(ApolloUserBadges *result) {
        typeof(self) ss = ws; if (!ss) return;
        if (![ss.username isEqualToString:user]) return;
        ss.userBadges = result;
        ss.fetchFailed = (result == nil);
        [ss.collectionView.refreshControl endRefreshing];
        [ss.collectionView reloadData];
        [ss apollo_updateLoadingUI];
    });
}

- (void)apollo_pullToRefresh:(UIRefreshControl *)refresh {
    ApolloBadgeBookInvalidate(self.username);
    self.userBadges = nil;
    self.fetchFailed = NO;
    [self.collectionView reloadData];
    [self apollo_startFetch];
    [self apollo_updateLoadingUI];
}

- (void)apollo_modeChanged {
    self.mode = (ApolloBadgeBookMode)self.segmented.selectedSegmentIndex;
    [self.collectionView reloadData];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    [self apollo_updateLoadingUI];
}

- (void)apollo_updateLoadingUI {
    BOOL loading = (self.userBadges == nil && !self.fetchFailed);
    // Achievements render immediately from the catalogue; only the Trophy Case has
    // nothing to show until the scrape resolves.
    if (self.mode == ApolloBadgeBookModeTrophies && loading) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }

    BOOL showEmpty = NO;
    NSString *emptyText = nil;
    if (self.mode == ApolloBadgeBookModeTrophies && !loading && self.userBadges.trophies.count == 0) {
        showEmpty = YES;
        emptyText = (self.userBadges && self.userBadges.trophiesResolved)
            ? [NSString stringWithFormat:@"u/%@ has no trophies yet.", self.username]
            : @"Couldn't load the Trophy Case.";
    } else if (self.mode == ApolloBadgeBookModeAchievements && !self.catalog.isLoaded) {
        showEmpty = YES;
        emptyText = @"Achievements are unavailable.";
    }
    self.emptyLabel.text = emptyText;
    self.emptyLabel.hidden = !showEmpty;
}

#pragma mark Data helpers

- (ApolloBadgeState)stateForAchievement:(ApolloBadgeItem *)item {
    if (!self.userBadges || !self.userBadges.achievementsResolved) return ApolloBadgeStateUnknown;
    return [self.userBadges.earnedAchievementIDs containsObject:item.identifier]
        ? ApolloBadgeStateEarned : ApolloBadgeStateLocked;
}

- (NSString *)artURLForItem:(ApolloBadgeItem *)item state:(ApolloBadgeState)state {
    if (item.kind != ApolloBadgeKindAchievement || state != ApolloBadgeStateEarned) return nil;
    return self.userBadges.earnedAchievementImageURLs[item.identifier];
}

- (NSArray<ApolloBadgeItem *> *)achievementsForSection:(NSInteger)section {
    NSString *cat = self.catalog.achievementCategories[section];
    return [self.catalog achievementsInCategory:cat];
}

#pragma mark UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    if (self.mode == ApolloBadgeBookModeAchievements) return self.catalog.achievementCategories.count;
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (self.mode == ApolloBadgeBookModeAchievements) return [self achievementsForSection:section].count;
    return self.userBadges.trophies.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloBadgeCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCellID forIndexPath:indexPath];
    cell.chipBackgroundColor = self.themeBackground;
    cell.placeholderFillColor = self.themeSurface;
    UIColor *accent = ApolloBBAccent(self.view);
    if (self.mode == ApolloBadgeBookModeAchievements) {
        ApolloBadgeItem *item = [self achievementsForSection:indexPath.section][indexPath.item];
        ApolloBadgeState state = [self stateForAchievement:item];
        [cell applyItem:item state:state accent:accent artURL:[self artURLForItem:item state:state]];
    } else {
        ApolloBadgeItem *item = self.userBadges.trophies[indexPath.item];
        [cell applyItem:item state:ApolloBadgeStateEarned accent:accent artURL:nil];
    }
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    ApolloBadgeSectionHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind
                                                                          withReuseIdentifier:kHeaderID
                                                                                 forIndexPath:indexPath];
    if (self.mode == ApolloBadgeBookModeAchievements) {
        NSString *cat = self.catalog.achievementCategories[indexPath.section];
        header.titleLabel.text = cat;
        NSArray<ApolloBadgeItem *> *items = [self achievementsForSection:indexPath.section];
        if (self.userBadges && self.userBadges.achievementsResolved) {
            NSInteger earned = 0;
            for (ApolloBadgeItem *i in items) if ([self.userBadges.earnedAchievementIDs containsObject:i.identifier]) earned++;
            header.countLabel.text = [NSString stringWithFormat:@"%ld / %lu", (long)earned, (unsigned long)items.count];
        } else {
            header.countLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)items.count];
        }
    } else {
        header.titleLabel.text = @"Trophy Case";
        header.countLabel.text = self.userBadges ? [NSString stringWithFormat:@"%lu", (unsigned long)self.userBadges.trophies.count] : @"";
    }
    return header;
}

#pragma mark UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UIEdgeInsets inset = ((UICollectionViewFlowLayout *)layout).sectionInset;
    CGFloat available = collectionView.bounds.size.width - inset.left - inset.right
        - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right;
    CGFloat spacing = 10.0;
    CGFloat target = 104.0;  // preferred cell width
    NSInteger cols = MAX(3, (NSInteger)floor((available + spacing) / (target + spacing)));
    CGFloat w = floor((available - spacing * (cols - 1)) / cols);
    // icon (≈w) + 2 lines of title AT THE CURRENT TEXT SIZE — the cell has to grow
    // with Dynamic Type or large accessibility sizes clip every title in the grid.
    return CGSizeMake(w, w + ApolloBBTitleHeight());
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
referenceSizeForHeaderInSection:(NSInteger)section {
    if (self.mode == ApolloBadgeBookModeAchievements && [self achievementsForSection:section].count == 0) return CGSizeZero;
    if (self.mode == ApolloBadgeBookModeTrophies && self.userBadges.trophies.count == 0) return CGSizeZero;
    return CGSizeMake(collectionView.bounds.size.width, ApolloBBHeaderHeight());
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    ApolloBadgeItem *item;
    ApolloBadgeState state;
    if (self.mode == ApolloBadgeBookModeAchievements) {
        item = [self achievementsForSection:indexPath.section][indexPath.item];
        state = [self stateForAchievement:item];
    } else {
        item = self.userBadges.trophies[indexPath.item];
        state = ApolloBadgeStateEarned;
    }
    ApolloBadgeDetailViewController *detail =
        [[ApolloBadgeDetailViewController alloc] initWithItem:item state:state accent:ApolloBBAccent(self.view)
                                                   background:self.themeBackground surface:self.themeSurface
                                                       artURL:[self artURLForItem:item state:state]
                                                     username:self.username];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
    detail.title = @"";
    detail.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(apollo_dismissDetail)];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) { sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent]; sheet.prefersGrabberVisible = YES; }
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)apollo_dismissDetail {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Presentation entry

void ApolloBadgeBookPresentForUsername(NSString *username, UIViewController *from) {
    if (username.length == 0 || !from) return;
    ApolloBadgeBookViewController *vc = [[ApolloBadgeBookViewController alloc] initWithUsername:username];
    vc.title = @"Badge Book";
    [vc apollo_captureThemeFromView:from.view];
    if (from.navigationController) {
        [from.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:vc action:@selector(apollo_dismissDetail)];
        [from presentViewController:nav animated:YES completion:nil];
    }
}

#if APOLLO_SIM_BUILD
// Sim-only test driver (compiled out of device builds). idb HID taps are broken
// under Xcode 27, so screens are driven via a Darwin notification + command file:
//   echo "<cmd>" > /tmp/apollofix-badgebook.txt
//   xcrun simctl spawn <UDID> notifyutil -p apollofix.badgebook.present
// Commands:
//   <user>                          present the Badge Book
//   <user> trophies                 present it on the Trophy Case tab
//   <user> detail <itemid> <earned|locked|unknown>   present the detail card
//   seed <user> <n>                 seed a cached result with the first n
//                                   achievements earned (tests placeholders live)
static UIViewController *ApolloBBSimTopVC(void) {
    UIWindow *key = nil;
    for (UIWindow *w in ApolloAllWindows()) { if (w.isKeyWindow) { key = w; break; } }
    if (!key) key = ApolloAllWindows().firstObject;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Descend containers to the visible CONTENT controller (the pushed screen), so
// commands can target Apollo's real nav stack rather than the tab/nav shells.
static UIViewController *ApolloBBSimContentVC(void) {
    UIViewController *vc = ApolloBBSimTopVC();
    while (1) {
        if ([vc isKindOfClass:[UITabBarController class]]) vc = ((UITabBarController *)vc).selectedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).topViewController;
        // The iPad pane layout inserts a split view controller under each tab.
        else if ([vc isKindOfClass:[UISplitViewController class]]) {
            UIViewController *column = ApolloContentColumnForSplitViewController((UISplitViewController *)vc);
            if (!column || column == vc) break;
            vc = column;
        }
        else break;
    }
    return vc;
}

static void ApolloBBSimHandleCommand(NSString *raw) {
    NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (parts.count == 0) return;
    UIViewController *top = ApolloBBSimTopVC();
    if (!top) return;

    // "dumpnav" — write the presented nav bar's recursive view hierarchy to
    // /tmp for Liquid Glass chrome diagnosis (private views don't show in the
    // accessibility tree idb exposes).
    if ([parts[0] isEqualToString:@"dumpnav"]) {
        UIViewController *content = ApolloBBSimContentVC();
        UINavigationController *nav = content.navigationController
            ?: ([top isKindOfClass:[UINavigationController class]] ? (UINavigationController *)top : top.navigationController);
        UIView *bar = nav.navigationBar ?: top.view.window;
        SEL sel = NSSelectorFromString(@"recursiveDescription");
        NSString *desc = bar ? ((NSString *(*)(id, SEL))objc_msgSend)(bar, sel) : @"(no bar)";
        [desc writeToFile:@"/tmp/apollofix-navdump.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        ApolloLog(@"[BadgeBook][sim] nav dump written (%lu chars)", (unsigned long)desc.length);
        return;
    }

    // "push <user>" — push the book onto the CURRENT nav stack (the same path a
    // strip tap takes), instead of the modal wrapper below. This is the config
    // where Apollo's own themed navigation bar hosts the segmented titleView.
    if ([parts[0] isEqualToString:@"push"] && parts.count >= 2) {
        UIViewController *content = ApolloBBSimContentVC();
        ApolloBadgeBookPresentForUsername(parts[1], content);
        ApolloLog(@"[BadgeBook][sim] pushed book for u/%@ onto %@", parts[1], NSStringFromClass([content class]));
        return;
    }

    if ([parts[0] isEqualToString:@"seed"] && parts.count >= 3) {
        NSString *user = parts[1];
        NSUInteger n = (NSUInteger)MAX(0, parts[2].integerValue);
        ApolloUserBadges *seeded = [[ApolloUserBadges alloc] init];
        seeded.username = user;
        NSMutableSet *earned = [NSMutableSet set];
        NSArray<ApolloBadgeItem *> *all = [ApolloBadgeBookCatalog shared].achievements;
        for (NSUInteger i = 0; i < MIN(n, all.count); i++) [earned addObject:all[i].identifier];
        seeded.earnedAchievementIDs = earned;
        seeded.achievementsResolved = YES;
        seeded.trophiesResolved = YES;
        ApolloBadgeBookDebugSeedResult(seeded);
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloBadgeBookUserUpdatedNotification object:user];
        ApolloLog(@"[BadgeBook][sim] seeded u/%@ with %lu earned", user, (unsigned long)earned.count);
        return;
    }

    NSString *user = parts[0];
    if (parts.count >= 4 && [parts[1] isEqualToString:@"detail"]) {
        NSString *itemID = parts[2];
        ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
        ApolloBadgeItem *item = [cat achievementWithIdentifier:itemID];
        if (!item) {
            for (ApolloBadgeItem *t in cat.trophies) {
                if ([t.identifier isEqualToString:itemID]) { item = t; break; }
            }
        }
        if (!item) { ApolloLog(@"[BadgeBook][sim] no catalogue item '%@'", itemID); return; }
        ApolloBadgeState state = ApolloBadgeStateUnknown;
        if ([parts[3] isEqualToString:@"earned"]) state = ApolloBadgeStateEarned;
        else if ([parts[3] isEqualToString:@"locked"]) state = ApolloBadgeStateLocked;
        UIColor *sampled = ApolloBBSampledBackground(top.view);
        ApolloBadgeDetailViewController *detail =
            [[ApolloBadgeDetailViewController alloc] initWithItem:item state:state
                                                           accent:ApolloBBAccent(top.view)
                                                       background:sampled
                                                          surface:(sampled ? ApolloBBElevatedColor(sampled) : nil)
                                                           artURL:nil
                                                         username:user];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            if (sheet) { sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent]; sheet.prefersGrabberVisible = YES; }
        }
        [top presentViewController:nav animated:YES completion:nil];
        return;
    }

    ApolloBadgeBookViewController *book = [[ApolloBadgeBookViewController alloc] initWithUsername:user];
    book.title = @"Badge Book";
    [book apollo_captureThemeFromView:top.view];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:book];
    book.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:book action:@selector(apollo_dismissDetail)];
    [top presentViewController:nav animated:YES completion:^{
        if (parts.count >= 2 && [parts[1] isEqualToString:@"trophies"]) {
            book.segmented.selectedSegmentIndex = 1;
            [book apollo_modeChanged];
        }
    }];
}

static void ApolloBBSimPresent(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    NSString *raw = [NSString stringWithContentsOfFile:@"/tmp/apollofix-badgebook.txt" encoding:NSUTF8StringEncoding error:nil];
    if (raw.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloBBSimHandleCommand(raw); });
}

__attribute__((constructor)) static void ApolloBBSimInit(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, ApolloBBSimPresent,
        CFSTR("apollofix.badgebook.present"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
#endif
