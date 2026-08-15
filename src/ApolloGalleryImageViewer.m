// ApolloGalleryImageViewer.m — see ApolloGalleryImageViewer.h.

#import "ApolloGalleryImageViewer.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloCommon.h"
#import "ApolloGalleryVideoExport.h"

#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

// Pages either side of the current one kept warm with their FULL-SIZE image.
// Deliberately shallow — full-res warm-up is the expensive kind of prefetch on
// image-heavy subreddits — and it drops to 0 for the session after a memory
// warning (the poster/thumbnail still shows instantly; only the sharpening
// waits for the page to become current).
static NSInteger const kApolloGalleryViewerPrefetchRadius = 1;
// Vertical drag (points) or flick velocity that commits the dismissal.
static CGFloat const kApolloGalleryViewerDismissDistance = 120.0;
static CGFloat const kApolloGalleryViewerDismissVelocity = 850.0;
// Start pulling the next batch once the user is within this many pictures of
// the end, so paging rarely stalls on the network.
static NSInteger const kApolloGalleryViewerLoadAheadSlack = 4;

static NSString *const kApolloGalleryViewerCellID = @"ApolloGalleryViewerCell";

// Mute state is sticky across pages and launches: someone browsing a video
// subreddit in public wants it to stay off, and re-muting every clip by hand
// would be miserable.
static NSString *const kApolloGalleryViewerMutedKey = @"ApolloGalleryVideosMuted";

static BOOL ApolloGalleryViewerVideosMuted(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Default to muted — audio starting unprompted in a scrolling gallery is
    // the worse surprise.
    id stored = [defaults objectForKey:kApolloGalleryViewerMutedKey];
    return stored ? [defaults boolForKey:kApolloGalleryViewerMutedKey] : YES;
}

static void ApolloGalleryViewerSetVideosMuted(BOOL muted) {
    [[NSUserDefaults standardUserDefaults] setBool:muted forKey:kApolloGalleryViewerMutedKey];
}

// (The post-info card's dismissal is deliberately NOT persisted — see
// `infoPanelHiddenForItem`: it belongs to the post it was dismissed on, so
// the next picture or video brings its own details back.)

// Apollo parks the shared session on Ambient, which is silenced by the ringer
// switch — so an unmuted clip would still play silently without this.
static void ApolloGalleryViewerActivateAudioSession(void) {
    if (ApolloGalleryViewerVideosMuted()) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        ApolloLog(@"[Gallery] audio session category failed: %@", error.localizedDescription);
        return;
    }
    [session setActive:YES error:NULL];
}

#pragma mark - Page cell

@interface ApolloGalleryViewerCell : UICollectionViewCell <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *zoomView;
// The zoomable content: the picture AND (for playables) the player layer both
// live on this one container, so pinch/double-tap zoom treats a video exactly
// like a photo — Apollo's own viewer does the same with its
// playerLayerContainerView inside the zoom scroll view.
@property (nonatomic, strong) UIView *mediaContainerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong, nullable) ApolloGalleryImageRequest *request;
@property (nonatomic, copy, nullable) NSURL *imageURL;
// Video side. The poster image stays underneath until the first frame is ready,
// so paging onto a clip never flashes black.
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, nullable) id playerEndObserver;
@property (nonatomic, copy, nullable) NSURL *videoURL;
@property (nonatomic, readonly) BOOL hasVideo;
// YES once the FULL-SIZE image is what's on screen. While it's NO, the image
// view is showing the grid's downsampled thumbnail as a placeholder — which
// Save/Share must never export.
@property (nonatomic) BOOL fullImageLoaded;
// Page size the zoom geometry was last computed for. The zoomView autoresizes
// with the cell, so comparing bounds against its frame can never detect a
// rotation — by the time layoutSubviews runs they already agree.
@property (nonatomic) CGSize zoomGeometrySize;
// Raised while a zoom is active so the pager and the dismiss pan stay out of
// the way (a zoomed page must pan its own content, not turn the page).
@property (nonatomic, readonly) BOOL isZoomed;
- (void)configureWithItem:(ApolloGalleryItem *)item;
- (void)replaceVideoURL:(nullable NSURL *)videoURL andPlay:(BOOL)play;
@end

@implementation ApolloGalleryViewerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.blackColor;
        self.contentView.backgroundColor = UIColor.blackColor;

        _zoomView = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
        _zoomView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _zoomView.delegate = self;
        _zoomView.minimumZoomScale = 1.0;
        _zoomView.maximumZoomScale = 5.0;
        _zoomView.showsHorizontalScrollIndicator = NO;
        _zoomView.showsVerticalScrollIndicator = NO;
        _zoomView.backgroundColor = UIColor.blackColor;
        _zoomView.bouncesZoom = YES;
        // Panning is only meaningful once zoomed in; while at 1x the paging
        // scroll view and the dismiss gesture own the touch.
        _zoomView.panGestureRecognizer.enabled = NO;
        if (@available(iOS 11.0, *)) {
            _zoomView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        [self.contentView addSubview:_zoomView];

        _mediaContainerView = [[UIView alloc] initWithFrame:_zoomView.bounds];
        _mediaContainerView.backgroundColor = UIColor.blackColor;
        [_zoomView addSubview:_mediaContainerView];

        _imageView = [[UIImageView alloc] initWithFrame:_mediaContainerView.bounds];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.backgroundColor = UIColor.blackColor;
        [_mediaContainerView addSubview:_imageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.color = UIColor.whiteColor;
        _spinner.hidesWhenStopped = YES;
        [self.contentView addSubview:_spinner];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(apollo_doubleTapped:)];
        doubleTap.numberOfTapsRequired = 2;
        [self.contentView addGestureRecognizer:doubleTap];
    }
    return self;
}

- (BOOL)isZoomed {
    return self.zoomView.zoomScale > self.zoomView.minimumZoomScale + 0.01;
}

- (BOOL)hasVideo {
    return self.player != nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.request cancel];
    self.request = nil;
    self.imageURL = nil;
    [self teardownPlayer];
    self.imageView.image = nil;
    self.fullImageLoaded = NO;
    self.zoomGeometrySize = CGSizeZero;
    self.zoomView.zoomScale = 1.0;
    self.zoomView.contentInset = UIEdgeInsetsZero;
    self.zoomView.panGestureRecognizer.enabled = NO;
    [self.spinner stopAnimating];
}

- (void)dealloc {
    [self teardownPlayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    BOOL boundsChanged = !CGSizeEqualToSize(bounds.size, self.zoomGeometrySize);
    self.zoomView.frame = bounds;
    self.spinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    // A bounds change (rotation, first layout) invalidates the zoom geometry.
    if (boundsChanged) [self apollo_resetZoomGeometry];
}

// The zoom view's content is the PICTURE, not the page. Sizing the container
// to the whole page instead would make the letterbox bars zoomable too, so a
// zoomed-in drag could pan off the photo into empty black.
- (void)apollo_resetZoomGeometry {
    UIImage *image = self.imageView.image;
    CGSize bounds = self.zoomView.bounds.size;
    if (bounds.width <= 0.0 || bounds.height <= 0.0) return;
    self.zoomGeometrySize = bounds;

    self.zoomView.zoomScale = 1.0;
    CGSize fitted = bounds;
    if (image && image.size.width > 0.0 && image.size.height > 0.0) {
        CGFloat scale = MIN(bounds.width / image.size.width, bounds.height / image.size.height);
        fitted = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));
        self.zoomView.panGestureRecognizer.enabled = NO;
    }
    self.mediaContainerView.frame = CGRectMake(0.0, 0.0, fitted.width, fitted.height);
    self.zoomView.contentSize = fitted;
    [self apollo_syncPlayerLayerFrame];
    [self apollo_centerContent];
}

// The player layer rides the media container (so zoom transforms carry it);
// only genuine container-bounds changes need an explicit frame sync, and those
// happen without animation so rotation doesn't rubber-band the video.
- (void)apollo_syncPlayerLayerFrame {
    if (!self.playerLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.playerLayer.frame = self.mediaContainerView.bounds;
    [CATransaction commit];
}

// Centres the picture with insets rather than by moving its frame, so the
// scroll view's own content bounds stay honest and panning clamps to the edges.
- (void)apollo_centerContent {
    CGSize bounds = self.zoomView.bounds.size;
    CGSize content = self.zoomView.contentSize;
    CGFloat vertical = MAX(0.0, (bounds.height - content.height) / 2.0);
    CGFloat horizontal = MAX(0.0, (bounds.width - content.width) / 2.0);
    self.zoomView.contentInset = UIEdgeInsetsMake(vertical, horizontal, vertical, horizontal);
}

// Setting up / tearing down playback ----------------------------------------

- (void)teardownPlayer {
    if (self.playerEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.playerEndObserver];
        self.playerEndObserver = nil;
    }
    [self.player pause];
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    self.player = nil;
    self.videoURL = nil;
}

- (void)prepareVideo:(NSURL *)url {
    if (!url) return;
    self.videoURL = url;

    AVPlayer *player = [AVPlayer playerWithURL:url];
    player.muted = ApolloGalleryViewerVideosMuted();
    // Clips are short and usually watched more than once; looping is what a
    // gallery reader expects and matches how Apollo plays GIF-ish media.
    __weak typeof(self) weakSelf = self;
    self.playerEndObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                          object:player.currentItem
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        [weakSelf.player seekToTime:kCMTimeZero];
        [weakSelf.player play];
    }];

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    // On the zoomable container, over the poster: pinching a playing video
    // zooms it exactly like a photo.
    layer.frame = self.mediaContainerView.bounds;
    [self.mediaContainerView.layer addSublayer:layer];

    self.player = player;
    self.playerLayer = layer;
}

- (void)playIfPossible {
    // Players are created LAZILY, for the current page only: adjacent pages a
    // paging collection view keeps materialized show their poster frame and
    // cost no AVPlayer, no buffering, no decoder session. The player appears
    // the moment its page becomes current (this method) and disappears with
    // cell reuse.
    if (!self.player && self.videoURL) [self prepareVideo:self.videoURL];
    if (!self.player) return;
    // Playback needs the session on a category that isn't silenced by the
    // ringer switch; Apollo parks it on Ambient, which mutes everything.
    ApolloGalleryViewerActivateAudioSession();
    self.player.muted = ApolloGalleryViewerVideosMuted();
    [self.player play];
}

- (void)pausePlayback {
    [self.player pause];
}

- (void)configureWithItem:(ApolloGalleryItem *)item {
    NSURL *url = item.imageURL;
    self.imageURL = url;
    // Stash the stream URL only; playIfPossible builds the player when this
    // page actually becomes current.
    // A hosted post deliberately waits on its original MP4 instead of starting
    // Reddit's silent preview while the host lookup is in flight.
    self.videoURL = (item.playsAsVideo && !item.needsHostedVideoResolution)
        ? item.videoURL : nil;

    // A grid thumbnail for this post is usually already decoded — show it
    // immediately so the page is never a black rectangle, then swap in the
    // full-size version when it lands.
    UIImage *placeholder = item.thumbnailURL ? [[ApolloGalleryImageLoader sharedLoader] cachedThumbnailForURL:item.thumbnailURL] : nil;
    UIImage *full = url ? [[ApolloGalleryImageLoader sharedLoader] cachedImageForURL:url] : nil;
    self.imageView.image = full ?: placeholder;
    self.fullImageLoaded = (full != nil);
    // The fit rect depends on the image's proportions, so re-derive it whenever
    // the displayed image changes — including the placeholder→full swap, which
    // can have a different aspect if Reddit's preview was cropped.
    [self apollo_resetZoomGeometry];

    if (full || !url) {
        [self.spinner stopAnimating];
        return;
    }
    [self.spinner startAnimating];

    __weak typeof(self) weakSelf = self;
    self.request = [[ApolloGalleryImageLoader sharedLoader] loadImageAtURL:url
                                                                  progress:nil
                                                                completion:^(UIImage *image, NSData *data) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // The cell may have been recycled onto a different picture while this
        // download was in flight.
        if (![strongSelf.imageURL isEqual:url]) return;
        [strongSelf.spinner stopAnimating];
        if (image) {
            strongSelf.imageView.image = image;
            strongSelf.fullImageLoaded = YES;
            [strongSelf apollo_resetZoomGeometry];
        }
        (void)data;
    }];
}

- (void)replaceVideoURL:(NSURL *)videoURL andPlay:(BOOL)play {
    if ([self.videoURL isEqual:videoURL]) {
        if (play) [self playIfPossible];
        return;
    }
    [self teardownPlayer];
    self.videoURL = videoURL;
    if (play) [self playIfPossible];
}

- (void)apollo_doubleTapped:(UITapGestureRecognizer *)recognizer {
    if (self.isZoomed) {
        [self.zoomView setZoomScale:self.zoomView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint point = [recognizer locationInView:self.imageView];
    CGFloat scale = MIN(self.zoomView.maximumZoomScale, 3.0);
    CGSize size = self.zoomView.bounds.size;
    CGRect target = CGRectMake(point.x - (size.width / scale) / 2.0,
                               point.y - (size.height / scale) / 2.0,
                               size.width / scale,
                               size.height / scale);
    [self.zoomView zoomToRect:target animated:YES];
}

#pragma mark UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.mediaContainerView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    scrollView.panGestureRecognizer.enabled = self.isZoomed;
    [self apollo_centerContent];
}

@end

// Chrome glyphs at a fixed point size. Left unconfigured, an SF Symbol scales
// to the button's font and filled the capsule edge to edge — which is what made
// the share button look cramped and off-centre (its arrow overshoots the glyph
// box, so tight bounds read as badly aligned rather than merely tight).
static UIImage *ApolloGalleryChromeSymbol(NSString *name) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:name withConfiguration:configuration];
}

// A chrome capsule: the material underneath, one content view (label or button)
// filling it.
//
// It lays out by frame rather than Auto Layout on purpose. These pills are
// frame-positioned from -apollo_layoutChrome and some start hidden, and
// constraints inside that subtree proved unreliable — a button pinned to all
// four edges stayed 0x0, so its symbol never drew.
//
// A container is also why the material isn't just inserted into the control:
//   • UILabel draws text into its own layer contents, which any subview covers;
//   • UIButton re-orders its subviews during layout on iOS 26, so a backdrop
//     inserted at index 0 ends up ON TOP of the image, leaving a blurred ghost
//     (the title escapes, which makes the bug look inconsistent).
@interface ApolloGalleryChromePillView : UIView
@property (nonatomic, strong, nullable) UIView *materialView;
@property (nonatomic, strong) UIView *pillContentView;
@end

@implementation ApolloGalleryChromePillView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.materialView.frame = self.bounds;
    self.pillContentView.frame = self.bounds;
    // Fully rounded, always: that makes a square icon button a circle and a
    // text pill a capsule, which is the shape Apple's own glass controls use.
    // A fixed radius on a 40x32 rect is what made these read as "tight boxes"
    // rather than iOS 26 controls.
    self.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2.0;
}
@end

// Builds a capsule around `content`. On Liquid Glass builds the backing is a
// real UIGlassEffect, so the viewer's controls match the rest of the iOS 26 app
// instead of reading as flat pre-26 pills; older builds keep translucent black,
// which is what stays legible over an arbitrary photo.
static ApolloGalleryChromePillView *ApolloGalleryChromePill(UIView *content, CGFloat legacyAlpha) {
    ApolloGalleryChromePillView *pill = [[ApolloGalleryChromePillView alloc] initWithFrame:CGRectZero];
    pill.clipsToBounds = YES;

    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (IsLiquidGlass() && glassClass) {
        pill.backgroundColor = UIColor.clearColor;
        id effect = [[glassClass alloc] init];
        // Interactive glass is what gives Apple's controls their press
        // response; without it the capsule is inert decoration.
        if ([effect respondsToSelector:@selector(setInteractive:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setInteractive:), YES);
        }
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:(UIVisualEffect *)effect];
        glass.userInteractionEnabled = NO;
        [pill addSubview:glass];
        pill.materialView = glass;
    } else {
        pill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:legacyAlpha];
    }

    content.backgroundColor = UIColor.clearColor;
    [pill addSubview:content];
    pill.pillContentView = content;
    return pill;
}

// Builds a chrome button and the view that should be positioned for it.
//
// On Liquid Glass we hand the whole job to UIKit's own glass button
// configuration rather than wrapping our own capsule around a plain button.
// That's what gets Apple's metrics — UIKit sizes the glass around the glyph, so
// the symbol is padded and optically centred instead of us guessing — and it's
// also what lets a button-attached UIMenu play the iOS 26 morph, since the
// button itself becomes the morph source. Elsewhere we fall back to the
// hand-rolled pill.
//
// Returns the button; `outHost` is what -apollo_layoutChrome should position
// (the button itself on glass, its pill otherwise).
static UIButton *ApolloGalleryChromeButton(UIImage *symbol, NSString *title, UIView *__strong *outHost) {
    if (IsLiquidGlass()) {
        if (@available(iOS 26.0, *)) {
            UIButtonConfiguration *configuration = [UIButtonConfiguration glassButtonConfiguration];
            configuration.image = symbol;
            configuration.title = title;
            configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
            UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
            button.tintColor = UIColor.whiteColor;
            if (outHost) *outHost = button;
            return button;
        }
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.whiteColor;
    if (symbol) [button setImage:symbol forState:UIControlStateNormal];
    if (title) {
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    }
    ApolloGalleryChromePillView *pill = ApolloGalleryChromePill(button, 0.55);
    if (outHost) *outHost = pill;
    return button;
}

#pragma mark - Viewer

@interface ApolloGalleryImageViewer () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                                        UIGestureRecognizerDelegate>
@property (nonatomic, strong) ApolloGalleryFeed *feed;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic) NSInteger currentIndex;
// Applied in -viewDidLayoutSubviews once the collection view has a real size;
// setting the offset before that lands on the wrong page.
@property (nonatomic) BOOL hasAppliedInitialIndex;
@property (nonatomic) NSInteger pendingInitialIndex;

@property (nonatomic, strong) UIView *topChrome;
@property (nonatomic, strong) UIButton *doneButton;
@property (nonatomic, strong) UIView *doneHost;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIView *shareHost;
@property (nonatomic, strong) UIButton *muteButton;
@property (nonatomic, strong) UIView *muteHost;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) ApolloGalleryChromePillView *counterPill;
@property (nonatomic, strong) UIView *infoPanel;
@property (nonatomic, strong, nullable) UIView *infoPanelMaterial;
@property (nonatomic, strong) UIButton *infoCloseButton;
@property (nonatomic, strong) UITapGestureRecognizer *infoTap;
// Dismissing the card gets you out of the way of THIS post, not every post:
// paging to another one (or reopening the viewer) shows its details again,
// since a new picture's title is new information rather than the thing you
// just chose to ignore.
@property (nonatomic) BOOL infoPanelHiddenForItem;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) ApolloGalleryChromePillView *statusPill;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) ApolloGalleryChromePillView *toastPill;
@property (nonatomic) BOOL chromeVisible;

// Video transport bar — the same control set Apollo's own VideoControlsView
// gives a fullscreen video (play/pause, ±15s, scrubber, time labels), bound
// to whichever page's player is current. Apollo's actual VideoControlsView
// can't be reused here: it's a Swift view whose delegate protocol and player
// wiring are Swift-only, so the tweak rebuilds the same controls on its own
// chrome. Hidden on still-image pages.
@property (nonatomic, strong) UIView *videoBarContentView;
@property (nonatomic, strong) ApolloGalleryChromePillView *videoBarPill;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *back15Button;
@property (nonatomic, strong) UIButton *forward15Button;
@property (nonatomic, strong) UISlider *videoSlider;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *durationLabel;
// The player the periodic observer is attached to. Strong on purpose: cell
// reuse can tear the cell's player down while our token is still registered,
// and removeTimeObserver: must be sent to the exact player that handed the
// token out — so the bar keeps the player alive until it unbinds.
@property (nonatomic, strong, nullable) AVPlayer *observedPlayer;
@property (nonatomic, strong, nullable) id videoTimeObserverToken;
// While the user is dragging the slider the periodic observer must not fight
// the thumb (Apollo's doNotUpdateVideoPositionSlider, same idea).
@property (nonatomic) BOOL videoScrubbing;
@property (nonatomic) BOOL videoResumeAfterScrub;
// Scrub seeks are coalesced (Apple QA1820, Apollo's seekInProgress): at most
// one seek in flight, remembering only the LATEST finger position. Firing a
// seek per slider tick instead made fast drags queue up requests the player
// chewed through one keyframe at a time — the picture trailed the finger.
@property (nonatomic) BOOL videoSeekInFlight;
@property (nonatomic) BOOL videoHasPendingSeek;
@property (nonatomic) NSTimeInterval videoPendingSeekSeconds;
// Hold-and-drag scrubbing on the video itself (Apollo's MediaViewer has the
// same gesture as scrubPanGestureRecognizer): the long-press arms on a video
// page, and horizontal movement past a small slop turns it into a scrub. A
// press that never moves falls through to the old actions sheet on release.
@property (nonatomic) BOOL gestureScrubArmed;
@property (nonatomic) BOOL gestureScrubActive;
@property (nonatomic) CGFloat gestureScrubStartX;
@property (nonatomic) NSTimeInterval gestureScrubStartTime;
@property (nonatomic) BOOL gestureScrubWasPlaying;

// Smart Rotation Lock (Apollo's `SmartRotationLockEnabled` setting): with
// iOS's own Portrait Orientation Lock on, UIKit will not auto-rotate no
// matter what mask we answer — so, exactly like Apollo's media viewer, we
// watch the PHYSICAL device orientation and offer a tap to rotate the media
// anyway. Nothing rotates without that tap, so an untouched orientation lock
// still behaves like an orientation lock.
@property (nonatomic, strong) UIButton *rotateOfferButton;
@property (nonatomic, strong) UIView *rotateOfferHost;
@property (nonatomic) UIInterfaceOrientation rotateOfferTargetOrientation;
@property (nonatomic) BOOL isForciblyRotated;
@property (nonatomic) NSUInteger rotateOfferGeneration;

@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;
@property (nonatomic) BOOL isDismissing;
// Full-res look-ahead: how deep (see kApolloGalleryViewerPrefetchRadius), and
// the outstanding warm-up handles keyed by item index so paging can cancel the
// ones that fell outside the window.
@property (nonatomic) NSInteger prefetchRadius;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ApolloGalleryImageRequest *> *viewerPrefetches;
@property (nonatomic) CGSize lastLaidOutSize;
@end

@implementation ApolloGalleryImageViewer

- (instancetype)initWithFeed:(ApolloGalleryFeed *)feed initialIndex:(NSInteger)initialIndex {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _feed = feed;
        _pendingInitialIndex = MAX(0, MIN(initialIndex, (NSInteger)feed.items.count - 1));
        _currentIndex = _pendingInitialIndex;
        _chromeVisible = YES;
        _prefetchRadius = kApolloGalleryViewerPrefetchRadius;
        _viewerPrefetches = [NSMutableDictionary dictionary];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalPresentationCapturesStatusBarAppearance = YES;
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

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    // The viewer is a black fullscreen surface with white text and icons, but
    // the APP is usually in light mode — so the iOS 26 glass pills first
    // resolved their LIGHT variant (white frost, unreadable white-on-white
    // labels) and only flipped dark once UIKit's adaptive glass sampled the
    // dark backdrop, a visible white→dark pop on every open. Pin the whole
    // hierarchy dark, like Apollo's own media viewer: glass renders its dark
    // variant from the first frame and the legacy translucent-black pills are
    // unaffected.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    self.layout = [[UICollectionViewFlowLayout alloc] init];
    self.layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    self.layout.minimumLineSpacing = 0.0;
    self.layout.minimumInteritemSpacing = 0.0;
    self.layout.sectionInset = UIEdgeInsetsZero;

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:self.layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.pagingEnabled = YES;
    self.collectionView.backgroundColor = UIColor.blackColor;
    self.collectionView.showsHorizontalScrollIndicator = NO;
    self.collectionView.alwaysBounceVertical = NO;
    if (@available(iOS 11.0, *)) {
        self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.collectionView registerClass:[ApolloGalleryViewerCell class] forCellWithReuseIdentifier:kApolloGalleryViewerCellID];
    [self.view addSubview:self.collectionView];

    [self apollo_buildChrome];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_singleTapped:)];
    tap.numberOfTapsRequired = 1;
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(apollo_longPressed:)];
    longPress.delegate = self;
    [self.view addGestureRecognizer:longPress];

    self.dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_dismissPanned:)];
    self.dismissPan.delegate = self;
    [self.view addGestureRecognizer:self.dismissPan];

    [self apollo_updateChromeContent];

    // Physical device orientation keeps reporting while the INTERFACE is
    // locked, which is what makes the smart-rotation offer possible.
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_deviceOrientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
}

// Presented on top of Apollo's portrait-locked stack, so the mask the
// container hierarchy answers only widens once ApolloGalleryOrientation sees
// THIS controller as the visible leaf. Poking on appear is what lets a wide
// video adopt the orientation the device is already being held at, instead of
// waiting for the next physical rotation.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // A forced rotation belongs to the viewer only: hand the app back to
    // portrait on the way out, or the feed underneath is left sideways while
    // the user's orientation lock says otherwise. Guarded on isBeingDismissed
    // so presenting a share sheet over the viewer doesn't unrotate it.
    if (self.isForciblyRotated && (self.isBeingDismissed || self.isDismissing)) {
        self.isForciblyRotated = NO;
        [self apollo_requestInterfaceOrientation:UIInterfaceOrientationPortrait];
    }
    // Nothing should keep playing behind or after the viewer.
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        if ([cell isMemberOfClass:[ApolloGalleryViewerCell class]]) {
            [(ApolloGalleryViewerCell *)cell pausePlayback];
        }
    }
}

- (void)dealloc {
    // The periodic transport observer must come off the exact player that
    // issued it before that player goes away.
    if (_observedPlayer && _videoTimeObserverToken) {
        [_observedPlayer removeTimeObserver:_videoTimeObserverToken];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIDeviceOrientationDidChangeNotification
                                                  object:nil];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // The loader is already dropping its caches; stop feeding it. Look-ahead
    // stays off for the rest of this viewer session — the current page still
    // loads full-res on demand, neighbours just wait until they're current.
    self.prefetchRadius = 0;
    for (ApolloGalleryImageRequest *request in self.viewerPrefetches.allValues) {
        [request cancel];
    }
    [self.viewerPrefetches removeAllObjects];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) return;

    if (!CGSizeEqualToSize(size, self.lastLaidOutSize)) {
        self.lastLaidOutSize = size;
        [self.layout invalidateLayout];
    }
    [self apollo_layoutChrome];

    // First real layout: jump to the tapped picture without an animation.
    if (!self.hasAppliedInitialIndex && self.feed.items.count > 0) {
        self.hasAppliedInitialIndex = YES;
        NSInteger index = MAX(0, MIN(self.pendingInitialIndex, (NSInteger)self.feed.items.count - 1));
        [self.collectionView layoutIfNeeded];
        [self.collectionView setContentOffset:CGPointMake(size.width * index, 0.0) animated:NO];
        self.currentIndex = index;
        [self apollo_updateChromeContent];
        // A video opens CLEAN — the clip is the point, and every control it
        // needs lives behind the same tap that toggles chrome everywhere
        // else. Still pictures keep the chrome up on arrival as before.
        if ([self apollo_currentItem].playsAsVideo && self.chromeVisible) {
            [self apollo_setChromeVisible:NO animated:NO];
        }
        [self apollo_syncPlayback];
        // That sync ran before the jumped-to page's cell existed (cells for
        // the new offset materialize on the NEXT layout pass), so a video
        // landing page had no player to start — the pass after the cells are
        // real is what actually begins playback on open.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf apollo_syncPlayback];
        });
        [self apollo_prefetchAroundIndex:index];
    } else if (self.hasAppliedInitialIndex) {
        // Rotation moves the page boundaries; re-anchor on the current picture.
        CGFloat expected = size.width * self.currentIndex;
        if (fabs(self.collectionView.contentOffset.x - expected) > 1.0 && !self.collectionView.isDragging) {
            [self.collectionView setContentOffset:CGPointMake(expected, 0.0) animated:NO];
        }
    }
}

#pragma mark Chrome

// Every overlay control sits on a translucent black capsule so it stays legible
// over an arbitrary photo — the same treatment in Liquid Glass and legacy
// builds, since the backdrop here is the picture, not app chrome.
- (void)apollo_buildChrome {
    self.doneButton = ApolloGalleryChromeButton(nil, @"Done", &_doneHost);
    [self.doneButton addTarget:self action:@selector(apollo_donePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.doneHost];

    self.counterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.counterLabel.textColor = UIColor.whiteColor;
    self.counterLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    self.counterPill = ApolloGalleryChromePill(self.counterLabel, 0.55);
    [self.view addSubview:self.counterPill];

    self.shareButton = ApolloGalleryChromeButton(ApolloGalleryChromeSymbol(@"square.and.arrow.up"), nil, &_shareHost);
    // A button-attached UIMenu, NOT a presented action sheet. That's what plays
    // the iOS 26 morph out of the button; an alert-controller popover gets no
    // such animation, which is why this felt unlike the rest of the app. The
    // menu itself is rebuilt per page in -apollo_updateChromeContent.
    self.shareButton.showsMenuAsPrimaryAction = YES;
    [self.view addSubview:self.shareHost];

    // Only shown while a video/GIF page is up; still images have nothing to mute.
    self.muteButton = ApolloGalleryChromeButton(ApolloGalleryChromeSymbol(@"speaker.slash.fill"), nil, &_muteHost);
    [self.muteButton addTarget:self action:@selector(apollo_muteTapped) forControlEvents:UIControlEventTouchUpInside];
    // Hidden until a page that can actually make noise is on screen.
    self.muteHost.hidden = YES;
    [self.view addSubview:self.muteHost];

    // Bottom-left post details. Tapping it leaves the gallery for the real post.
    // The info panel positions its own labels, so it gets the material directly
    // rather than through a pill; a plain UIView doesn't reorder subviews.
    self.infoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.infoPanel.layer.cornerRadius = 14.0;
    self.infoPanel.layer.cornerCurve = kCACornerCurveContinuous;
    self.infoPanel.clipsToBounds = YES;
    {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (IsLiquidGlass() && glassClass) {
            self.infoPanel.backgroundColor = UIColor.clearColor;
            UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[[glassClass alloc] init]];
            glass.userInteractionEnabled = NO;
            glass.frame = self.infoPanel.bounds;
            glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self.infoPanel addSubview:glass];
            self.infoPanelMaterial = glass;
        } else {
            self.infoPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        }
    }
    [self.view addSubview:self.infoPanel];

    // (material added above sits at index 0, behind these labels)
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 2;
    [self.infoPanel addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.subtitleLabel.numberOfLines = 1;
    [self.infoPanel addSubview:self.subtitleLabel];

    self.infoTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                           action:@selector(apollo_infoPanelTapped)];
    self.infoTap.delegate = self;
    [self.infoPanel addGestureRecognizer:self.infoTap];

    // Dismissing the card is what makes the transport usable on its own: the
    // title block is the tallest piece of chrome, and on a wide video it is
    // the part most likely to be in the way.
    self.infoCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.infoCloseButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    [self.infoCloseButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"
                                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                                                              weight:UIImageSymbolWeightSemibold]]
                          forState:UIControlStateNormal];
    self.infoCloseButton.accessibilityLabel = @"Hide Post Info";
    [self.infoCloseButton addTarget:self action:@selector(apollo_hideInfoPanelTapped)
                   forControlEvents:UIControlEventTouchUpInside];
    [self.infoPanel addSubview:self.infoCloseButton];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusPill = ApolloGalleryChromePill(self.statusLabel, 0.55);
    self.statusPill.alpha = 0.0;
    [self.view addSubview:self.statusPill];

    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toastLabel.textColor = UIColor.whiteColor;
    self.toastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastPill = ApolloGalleryChromePill(self.toastLabel, 0.7);
    self.toastPill.alpha = 0.0;
    [self.view addSubview:self.toastPill];

    [self apollo_buildVideoBar];

    self.rotateOfferButton = ApolloGalleryChromeButton(ApolloGalleryChromeSymbol(@"rotate.right"),
                                                       @"Tap to Rotate", &_rotateOfferHost);
    [self.rotateOfferButton addTarget:self action:@selector(apollo_rotateOfferTapped)
                     forControlEvents:UIControlEventTouchUpInside];
    self.rotateOfferHost.hidden = YES;
    [self.view addSubview:self.rotateOfferHost];
}

#pragma mark Smart Rotation Lock

// Apollo's own setting, read live so toggling it in Settings takes effect on
// the next page. Absent means on: that is how Apollo ships it.
static BOOL ApolloGallerySmartRotationLockEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"SmartRotationLockEnabled"];
    return stored ? [stored boolValue] : YES;
}

static UIInterfaceOrientation ApolloGalleryInterfaceOrientationForDevice(UIDeviceOrientation device) {
    // The landscape cases are deliberately crossed: a device rotated left
    // presents a right-hand-side-up interface.
    switch (device) {
        case UIDeviceOrientationLandscapeLeft:  return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationLandscapeLeft;
        case UIDeviceOrientationPortrait:       return UIInterfaceOrientationPortrait;
        default:                                return UIInterfaceOrientationUnknown;
    }
}

- (UIInterfaceOrientation)apollo_currentInterfaceOrientation {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene) return scene.interfaceOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

// Debounced: a physical turn passes through several intermediate readings
// (including face-up/face-down), and UIKit needs a beat to settle its own
// rotation when the lock is OFF — offering a button mid-turn would flash it
// on every unlocked rotation too.
- (void)apollo_deviceOrientationChanged:(NSNotification *)notification {
    NSUInteger generation = ++self.rotateOfferGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.rotateOfferGeneration != generation) return;
        [strongSelf apollo_updateRotationOffer];
    });
    (void)notification;
}

- (void)apollo_updateRotationOffer {
    if (self.isDismissing || !ApolloGallerySmartRotationLockEnabled()) {
        [self apollo_hideRotationOffer];
        return;
    }

    UIInterfaceOrientation wanted = ApolloGalleryInterfaceOrientationForDevice(UIDevice.currentDevice.orientation);
    if (wanted == UIInterfaceOrientationUnknown) return;   // flat on a table: keep whatever is showing
    UIInterfaceOrientation current = [self apollo_currentInterfaceOrientation];
    // Already agreeing means the lock is off (UIKit rotated by itself) or the
    // user already accepted an offer — either way there is nothing to offer.
    if (wanted == current) {
        [self apollo_hideRotationOffer];
        return;
    }

    ApolloGalleryItem *item = [self apollo_currentItem];
    NSString *noun = @"Image";
    if (item.playsAsVideo) noun = @"Video";
    else if (item.kind == ApolloGalleryMediaKindGIF) noun = @"GIF";
    BOOL rotatingBack = UIInterfaceOrientationIsPortrait(wanted) && self.isForciblyRotated;
    NSString *title = rotatingBack ? @"Tap to Rotate Back"
                                   : [NSString stringWithFormat:@"Tap to Rotate %@", noun];

    self.rotateOfferTargetOrientation = wanted;
    [self.rotateOfferButton setTitle:title forState:UIControlStateNormal];
    if (self.rotateOfferButton.configuration) {
        UIButtonConfiguration *configuration = self.rotateOfferButton.configuration;
        configuration.title = title;
        self.rotateOfferButton.configuration = configuration;
    }
    if (self.rotateOfferHost.hidden) {
        self.rotateOfferHost.hidden = NO;
        self.rotateOfferHost.alpha = 0.0;
        [UIView animateWithDuration:0.2 animations:^{ self.rotateOfferHost.alpha = 1.0; }];
    }
    [self.view setNeedsLayout];
}

- (void)apollo_hideRotationOffer {
    if (self.rotateOfferHost.hidden) return;
    [UIView animateWithDuration:0.2 animations:^{
        self.rotateOfferHost.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.rotateOfferHost.hidden = YES;
        (void)finished;
    }];
}

- (void)apollo_rotateOfferTapped {
    UIInterfaceOrientation target = self.rotateOfferTargetOrientation;
    if (target == UIInterfaceOrientationUnknown) return;
    [self apollo_hideRotationOffer];
    // Forcing geometry is the ONLY thing that moves a locked interface, which
    // is why this lives behind an explicit tap.
    self.isForciblyRotated = !UIInterfaceOrientationIsPortrait(target);
    [self apollo_requestInterfaceOrientation:target];
}

- (void)apollo_requestInterfaceOrientation:(UIInterfaceOrientation)orientation {
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (!scene) return;
        UIInterfaceOrientationMask mask;
        switch (orientation) {
            case UIInterfaceOrientationLandscapeLeft:  mask = UIInterfaceOrientationMaskLandscapeLeft; break;
            case UIInterfaceOrientationLandscapeRight: mask = UIInterfaceOrientationMaskLandscapeRight; break;
            default:                                   mask = UIInterfaceOrientationMaskPortrait; break;
        }
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
            ApolloLog(@"[Gallery] rotate request failed: %@", error.localizedDescription);
        }];
    }
}

// One capsule holding the whole transport row; children are frame-positioned
// from -apollo_layoutChrome like every other chrome element (see the pill
// class comment for why Auto Layout is avoided in this subtree).
- (void)apollo_buildVideoBar {
    self.videoBarContentView = [[UIView alloc] initWithFrame:CGRectZero];

    UIButton * (^transportButton)(NSString *, SEL) = ^UIButton *(NSString *symbol, SEL action) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = UIColor.whiteColor;
        [button setImage:ApolloGalleryChromeSymbol(symbol) forState:UIControlStateNormal];
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [self.videoBarContentView addSubview:button];
        return button;
    };
    self.playPauseButton = transportButton(@"pause.fill", @selector(apollo_playPauseTapped));
    self.playPauseButton.accessibilityLabel = @"Pause";
    self.back15Button = transportButton(@"gobackward.15", @selector(apollo_back15Tapped));
    self.back15Button.accessibilityLabel = @"Back 15 seconds";
    self.forward15Button = transportButton(@"goforward.15", @selector(apollo_forward15Tapped));
    self.forward15Button.accessibilityLabel = @"Forward 15 seconds";

    UILabel * (^timeLabel)(NSTextAlignment) = ^UILabel *(NSTextAlignment alignment) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightSemibold];
        label.textAlignment = alignment;
        label.text = @"0:00";
        [self.videoBarContentView addSubview:label];
        return label;
    };
    self.currentTimeLabel = timeLabel(NSTextAlignmentRight);
    self.durationLabel = timeLabel(NSTextAlignmentLeft);

    self.videoSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.videoSlider.minimumValue = 0.0;
    self.videoSlider.maximumValue = 1.0;
    self.videoSlider.minimumTrackTintColor = UIColor.whiteColor;
    self.videoSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    [self.videoSlider addTarget:self action:@selector(apollo_sliderTouchedDown)
               forControlEvents:UIControlEventTouchDown];
    [self.videoSlider addTarget:self action:@selector(apollo_sliderValueChanged)
               forControlEvents:UIControlEventValueChanged];
    [self.videoSlider addTarget:self action:@selector(apollo_sliderTouchEnded)
               forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
    [self.videoBarContentView addSubview:self.videoSlider];

    self.videoBarPill = ApolloGalleryChromePill(self.videoBarContentView, 0.55);
    self.videoBarPill.hidden = YES;
    [self.view addSubview:self.videoBarPill];
}

- (void)apollo_layoutChrome {
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.view.safeAreaInsets;

    CGFloat top = safe.top + 12.0;
    CGFloat side = MAX(16.0, safe.left + 16.0);
    CGFloat rightSide = MAX(16.0, safe.right + 16.0);

    // Icon buttons are SQUARE, so the capsule renders as a circle — the shape
    // Apple uses for single-glyph glass controls. The old 40x32 rect with a
    // fixed 16pt radius is what made them read as tight little boxes.
    CGFloat const controlHeight = 36.0;
    CGFloat const iconSize = controlHeight;
    CGFloat const controlGap = 8.0;

    self.doneHost.frame = CGRectMake(side, top, 74.0, controlHeight);
    self.shareHost.frame = CGRectMake(bounds.size.width - rightSide - iconSize, top, iconSize, controlHeight);
    CGFloat trailing = CGRectGetMinX(self.shareHost.frame);
    if (!self.muteHost.hidden) {
        self.muteHost.frame = CGRectMake(trailing - controlGap - iconSize, top, iconSize, controlHeight);
        trailing = CGRectGetMinX(self.muteHost.frame);
    }
    CGFloat counterWidth = 88.0;
    self.counterPill.frame = CGRectMake(trailing - controlGap - counterWidth, top, counterWidth, controlHeight);
    self.statusPill.frame = CGRectMake((bounds.size.width - 156.0) / 2.0, CGRectGetMaxY(self.counterPill.frame) + 8.0, 156.0, 28.0);

    CGFloat bottom = safe.bottom + 16.0;
    // Two different widths on purpose. The info panel keeps a readable line
    // length, so it stays capped; the transport is a scrubber and takes the
    // whole width it can get — capping it too is what left the controls
    // huddled in the left half of a landscape screen.
    CGFloat availableWidth = bounds.size.width - side - rightSide;
    CGFloat panelWidth = MIN(availableWidth, 460.0);
    CGFloat videoBarWidth = availableWidth;
    CGFloat textWidth = panelWidth - 24.0;

    // The close button eats into the title's line, so the text measures
    // against the narrower column.
    CGFloat const closeSize = 28.0;
    CGFloat closeInset = closeSize + 8.0;
    textWidth -= closeInset;

    CGSize titleSize = CGSizeZero;
    if (self.titleLabel.text.length > 0) {
        titleSize = [self.titleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        titleSize.width = textWidth;
    }
    CGSize subtitleSize = CGSizeZero;
    if (self.subtitleLabel.text.length > 0) {
        subtitleSize = [self.subtitleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        subtitleSize.width = textWidth;
    }
    CGFloat gap = (titleSize.height > 0.0 && subtitleSize.height > 0.0) ? 3.0 : 0.0;
    CGFloat panelHeight = 20.0 + titleSize.height + gap + subtitleSize.height;
    BOOL showsInfo = (titleSize.height + subtitleSize.height) > 0.0 && !self.infoPanelHiddenForItem;
    self.infoPanel.hidden = !showsInfo;
    self.titleLabel.frame = CGRectMake(12.0, 10.0, titleSize.width, titleSize.height);
    self.subtitleLabel.frame = CGRectMake(12.0, 10.0 + titleSize.height + gap, subtitleSize.width, subtitleSize.height);
    self.infoCloseButton.frame = CGRectMake(panelWidth - closeSize - 8.0,
                                            (panelHeight - closeSize) / 2.0, closeSize, closeSize);

    CGFloat const videoBarHeight = 44.0;
    BOOL showsBar = !self.videoBarPill.hidden;
    // The transport owns the bottom edge in both orientations — where a video
    // player's controls belong — with the post card stacked above it. On a
    // still image there is no transport, so the card takes the bottom itself.
    CGFloat barY = bounds.size.height - bottom - videoBarHeight;
    self.videoBarPill.frame = CGRectMake(side, barY, videoBarWidth, videoBarHeight);
    CGFloat infoBottom = showsBar ? (barY - 8.0) : (bounds.size.height - bottom);
    self.infoPanel.frame = CGRectMake(side, infoBottom - panelHeight, panelWidth, panelHeight);
    {
        CGFloat const buttonSize = 36.0;
        CGFloat const buttonGap = 2.0;
        CGFloat const edgePadding = 8.0;
        CGFloat const timeWidth = 44.0;
        CGFloat barMidY = videoBarHeight / 2.0;
        CGFloat x = edgePadding;
        self.playPauseButton.frame = CGRectMake(x, barMidY - buttonSize / 2.0, buttonSize, buttonSize);
        x = CGRectGetMaxX(self.playPauseButton.frame) + buttonGap;
        self.back15Button.frame = CGRectMake(x, barMidY - buttonSize / 2.0, buttonSize, buttonSize);
        x = CGRectGetMaxX(self.back15Button.frame) + buttonGap;
        self.forward15Button.frame = CGRectMake(x, barMidY - buttonSize / 2.0, buttonSize, buttonSize);

        CGFloat durationRight = videoBarWidth - edgePadding - 4.0;
        self.durationLabel.frame = CGRectMake(durationRight - timeWidth, barMidY - 9.0, timeWidth, 18.0);
        CGFloat sliderLeft = CGRectGetMaxX(self.forward15Button.frame) + 6.0 + timeWidth + 6.0;
        self.currentTimeLabel.frame = CGRectMake(CGRectGetMaxX(self.forward15Button.frame) + 6.0,
                                                 barMidY - 9.0, timeWidth, 18.0);
        CGFloat sliderRight = CGRectGetMinX(self.durationLabel.frame) - 6.0;
        self.videoSlider.frame = CGRectMake(sliderLeft, barMidY - 16.0,
                                            MAX(sliderRight - sliderLeft, 40.0), 32.0);
    }

    // Rotation offer: centered just under the top chrome, clear of the
    // controls at the bottom.
    if (!self.rotateOfferHost.hidden) {
        CGSize offerSize = [self.rotateOfferHost sizeThatFits:CGSizeMake(bounds.size.width - 2.0 * side, 44.0)];
        CGFloat offerWidth = MIN(MAX(offerSize.width, 180.0), bounds.size.width - 2.0 * side);
        self.rotateOfferHost.frame = CGRectMake((bounds.size.width - offerWidth) / 2.0,
                                                top + controlHeight + 12.0, offerWidth, 40.0);
    }

    // Above whichever bottom pill is highest, so the toast never lands on the
    // controls in either orientation.
    CGFloat toastAnchor = bounds.size.height - bottom;
    if (showsBar) toastAnchor = MIN(toastAnchor, CGRectGetMinY(self.videoBarPill.frame));
    if (showsInfo) toastAnchor = MIN(toastAnchor, CGRectGetMinY(self.infoPanel.frame));
    self.toastPill.frame = CGRectMake((bounds.size.width - 220.0) / 2.0,
                                       toastAnchor - 46.0,
                                       220.0, 32.0);
}

#pragma mark Video transport

static NSString *ApolloGalleryTimeString(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
}

// The duration the transport math should trust: the loaded item's own when
// it's known, else what Reddit reported for the post.
- (NSTimeInterval)apollo_currentVideoDuration {
    AVPlayerItem *item = self.observedPlayer.currentItem;
    CMTime duration = item ? item.duration : kCMTimeInvalid;
    if (CMTIME_IS_NUMERIC(duration) && CMTimeGetSeconds(duration) > 0.0) {
        return CMTimeGetSeconds(duration);
    }
    return [self apollo_currentItem].duration;
}

// Attach the transport to (exactly) the current page's player. Safe to call
// repeatedly — rebinding to the same player is a no-op, so the sync passes
// that fire on every page settle don't churn observers.
- (void)apollo_bindVideoBarToPlayer:(AVPlayer *)player {
    if (player == self.observedPlayer) {
        [self apollo_refreshVideoBarNow];
        return;
    }
    if (self.observedPlayer && self.videoTimeObserverToken) {
        [self.observedPlayer removeTimeObserver:self.videoTimeObserverToken];
    }
    self.videoTimeObserverToken = nil;
    self.observedPlayer = player;
    self.videoScrubbing = NO;
    if (!player) {
        [self apollo_refreshVideoBarNow];
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.videoTimeObserverToken =
        [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                             queue:dispatch_get_main_queue()
                                        usingBlock:^(CMTime time) {
        [weakSelf apollo_refreshVideoBarNow];
        (void)time;
    }];
    [self apollo_refreshVideoBarNow];
}

- (void)apollo_refreshVideoBarNow {
    AVPlayer *player = self.observedPlayer;
    ApolloGalleryItem *item = [self apollo_currentItem];
    BOOL showsBar = item.playsAsVideo;
    self.videoBarPill.hidden = !showsBar;
    if (!showsBar) return;

    NSTimeInterval duration = [self apollo_currentVideoDuration];
    NSTimeInterval current = player ? CMTimeGetSeconds(player.currentTime) : 0.0;
    if (!isfinite(current) || current < 0.0) current = 0.0;
    if (duration > 0.0) current = MIN(current, duration);

    self.currentTimeLabel.text = ApolloGalleryTimeString(current);
    self.durationLabel.text = ApolloGalleryTimeString(duration);
    if (!self.videoScrubbing) {
        self.videoSlider.value = duration > 0.0 ? (float)(current / duration) : 0.0f;
    }
    self.videoSlider.enabled = (player != nil && duration > 0.0);
    self.back15Button.enabled = (player != nil);
    self.forward15Button.enabled = (player != nil);
    self.playPauseButton.enabled = (player != nil);

    BOOL playing = player && player.rate > 0.0f;
    [self.playPauseButton setImage:ApolloGalleryChromeSymbol(playing ? @"pause.fill" : @"play.fill")
                          forState:UIControlStateNormal];
    self.playPauseButton.accessibilityLabel = playing ? @"Pause" : @"Play";
}

// The one entry point for scrub-time seeks (slider and hold-drag both).
// Loose tolerance keeps the preview frame cheap; the coalescing keeps the
// player working on exactly one position — the newest — instead of a backlog.
- (void)apollo_scrubSeekToSeconds:(NSTimeInterval)target {
    AVPlayer *player = self.observedPlayer;
    if (!player) return;
    if (self.videoSeekInFlight) {
        self.videoPendingSeekSeconds = target;
        self.videoHasPendingSeek = YES;
        return;
    }
    self.videoSeekInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [player seekToTime:CMTimeMakeWithSeconds(target, 600)
       toleranceBefore:kCMTimePositiveInfinity
        toleranceAfter:kCMTimePositiveInfinity
     completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.videoSeekInFlight = NO;
            if (strongSelf.videoHasPendingSeek) {
                strongSelf.videoHasPendingSeek = NO;
                [strongSelf apollo_scrubSeekToSeconds:strongSelf.videoPendingSeekSeconds];
            }
        });
        (void)finished;
    }];
}

- (void)apollo_playPauseTapped {
    AVPlayer *player = self.observedPlayer;
    if (!player) return;
    if (player.rate > 0.0f) {
        [player pause];
    } else {
        // Play at the end restarts, like Apollo's own play button on a
        // finished clip (the loop normally hides this, but a paused-at-end
        // player can land here).
        NSTimeInterval duration = [self apollo_currentVideoDuration];
        NSTimeInterval current = CMTimeGetSeconds(player.currentTime);
        if (duration > 0.0 && current >= duration - 0.1) {
            [player seekToTime:kCMTimeZero];
        }
        [[self apollo_currentCell] playIfPossible];
    }
    [self apollo_refreshVideoBarNow];
}

- (void)apollo_seekRelative:(NSTimeInterval)delta {
    AVPlayer *player = self.observedPlayer;
    if (!player) return;
    NSTimeInterval duration = [self apollo_currentVideoDuration];
    NSTimeInterval target = CMTimeGetSeconds(player.currentTime) + delta;
    if (!isfinite(target)) return;
    target = MAX(0.0, duration > 0.0 ? MIN(target, MAX(duration - 0.1, 0.0)) : target);
    [player seekToTime:CMTimeMakeWithSeconds(target, 600)
       toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
     completionHandler:^(BOOL finished) { (void)finished; }];
    [self apollo_refreshVideoBarNow];
}

- (void)apollo_back15Tapped { [self apollo_seekRelative:-15.0]; }
- (void)apollo_forward15Tapped { [self apollo_seekRelative:15.0]; }

- (void)apollo_sliderTouchedDown {
    self.videoScrubbing = YES;
    AVPlayer *player = self.observedPlayer;
    self.videoResumeAfterScrub = (player.rate > 0.0f);
    [player pause];
}

- (void)apollo_sliderValueChanged {
    NSTimeInterval duration = [self apollo_currentVideoDuration];
    if (!self.observedPlayer || duration <= 0.0) return;
    NSTimeInterval target = self.videoSlider.value * duration;
    self.currentTimeLabel.text = ApolloGalleryTimeString(target);
    [self apollo_scrubSeekToSeconds:target];
}

- (void)apollo_sliderTouchEnded {
    AVPlayer *player = self.observedPlayer;
    NSTimeInterval duration = [self apollo_currentVideoDuration];
    if (player && duration > 0.0) {
        NSTimeInterval target = self.videoSlider.value * duration;
        // Landing exactly on the very end would fire the loop's
        // did-play-to-end and snap back to 0 — stop a whisker short instead.
        target = MIN(target, MAX(duration - 0.1, 0.0));
        // The precise landing seek supersedes anything still coalescing.
        self.videoHasPendingSeek = NO;
        __weak typeof(self) weakSelf = self;
        [player seekToTime:CMTimeMakeWithSeconds(target, 600)
           toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero
         completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.videoScrubbing = NO;
                if (strongSelf.videoResumeAfterScrub) {
                    [[strongSelf apollo_currentCell] playIfPossible];
                }
                [strongSelf apollo_refreshVideoBarNow];
            });
            (void)finished;
        }];
    } else {
        self.videoScrubbing = NO;
    }
}

- (void)apollo_updateChromeContent {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    NSInteger total = (NSInteger)items.count;
    NSInteger index = MAX(0, MIN(self.currentIndex, total - 1));

    if (total > 0) {
        // Running position out of everything loaded so far. The total grows as
        // batches land, which is the honest read on "how much is there" — more
        // useful than restarting the count at every batch boundary.
        self.counterLabel.text = [NSString stringWithFormat:@"%ld / %ld", (long)index + 1, (long)total];
    } else {
        self.counterLabel.text = @"";
    }

    ApolloGalleryItem *item = (index >= 0 && index < total) ? items[index] : nil;
    self.titleLabel.text = item.postTitle ?: @"";
    [self apollo_updateMuteButton];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (item.author.length > 0) [parts addObject:[@"u/" stringByAppendingString:item.author]];
    if (item.subreddit.length > 0) [parts addObject:[@"r/" stringByAppendingString:item.subreddit]];
    if (item.galleryCount > 1) {
        [parts addObject:[NSString stringWithFormat:@"%ld of %ld in post",
                          (long)item.galleryIndex + 1, (long)item.galleryCount]];
    }
    self.subtitleLabel.text = [parts componentsJoinedByString:@" · "];
    // The actions depend on the current item, so rebuild per page.
    self.shareButton.menu = [self apollo_buildActionsMenu];

    [self.view setNeedsLayout];
}

- (void)apollo_setChromeVisible:(BOOL)visible animated:(BOOL)animated {
    self.chromeVisible = visible;
    CGFloat alpha = visible ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        self.doneHost.alpha = alpha;
        self.shareHost.alpha = alpha;
        self.muteHost.alpha = alpha;
        self.counterPill.alpha = alpha;
        self.infoPanel.alpha = alpha;
        self.videoBarPill.alpha = alpha;
    };
    self.doneHost.userInteractionEnabled = visible;
    self.shareHost.userInteractionEnabled = visible;
    self.muteHost.userInteractionEnabled = visible;
    self.infoPanel.userInteractionEnabled = visible;
    self.videoBarPill.userInteractionEnabled = visible;
    if (animated) {
        [UIView animateWithDuration:0.22 animations:changes];
    } else {
        changes();
    }
}

- (void)apollo_setStatus:(NSString *)status {
    self.statusLabel.text = status;
    BOOL show = status.length > 0;
    [UIView animateWithDuration:0.2 animations:^{
        self.statusPill.alpha = show ? 1.0 : 0.0;
    }];
}

- (void)apollo_showToast:(NSString *)text {
    self.toastLabel.text = text;
    [self.view bringSubviewToFront:self.toastPill];
    [UIView animateWithDuration:0.2 animations:^{ self.toastPill.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ self.toastPill.alpha = 0.0; }];
    });
}

#pragma mark Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.feed.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloGalleryViewerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kApolloGalleryViewerCellID
                                                                             forIndexPath:indexPath];
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (indexPath.item < (NSInteger)items.count) {
        [cell configureWithItem:items[indexPath.item]];
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGSize size = self.view.bounds.size;
    return CGSizeMake(MAX(size.width, 1.0), MAX(size.height, 1.0));
}

#pragma mark Paging

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) return;
    // Mid-rotation this fires with transitional geometry — the old offset
    // divided by the new width — which lands on an unrelated page and clobbers
    // currentIndex before viewDidLayoutSubviews can re-anchor on it. Page math
    // is only meaningful once the bounds match the size the layout was
    // prepared for; until then, keep the page the user was on.
    if (!CGSizeEqualToSize(scrollView.bounds.size, self.lastLaidOutSize)) return;
    CGFloat width = MAX(self.collectionView.bounds.size.width, 1.0);
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / width);
    page = MAX(0, MIN(page, (NSInteger)self.feed.items.count - 1));
    if (page == self.currentIndex) return;
    self.currentIndex = page;
    // A different post carries different details, so it starts with its card
    // showing even if the last one's was dismissed.
    self.infoPanelHiddenForItem = NO;
    [self apollo_updateChromeContent];
    [self apollo_syncPlayback];
    [self apollo_prefetchAroundIndex:page];
    [self apollo_loadMoreIfNeeded];
}

// Exactly one page plays at a time: every other visible cell (the neighbours a
// paging collection view keeps alive) gets paused, so audio can't stack up.
- (void)apollo_syncPlayback {
    ApolloGalleryItem *currentItem = [self apollo_currentItem];
    if (currentItem.needsHostedVideoResolution && !currentItem.isHostedVideoResolving) {
        __weak typeof(self) weakSelf = self;
        [currentItem resolveHostedVideoWithCompletion:^(BOOL resolvedOriginal) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || [strongSelf apollo_currentItem] != currentItem) return;
            ApolloGalleryViewerCell *currentCell = [strongSelf apollo_currentCell];
            [currentCell replaceVideoURL:currentItem.videoURL andPlay:YES];
            [strongSelf apollo_updateChromeContent];
            // The resolution just swapped in a fresh player; repoint the
            // transport at it (the pre-resolution bind saw nil).
            [strongSelf apollo_bindVideoBarToPlayer:currentCell.player];
            if (!resolvedOriginal && !currentItem.videoURL) {
                [strongSelf apollo_showToast:@"Couldn't load video"];
            }
        }];
    }

    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        if (![cell isMemberOfClass:[ApolloGalleryViewerCell class]]) continue;
        ApolloGalleryViewerCell *viewerCell = (ApolloGalleryViewerCell *)cell;
        NSIndexPath *indexPath = [self.collectionView indexPathForCell:cell];
        if (indexPath.item == self.currentIndex) {
            [viewerCell playIfPossible];
        } else {
            [viewerCell pausePlayback];
        }
    }
    [self apollo_updateMuteButton];
    // playIfPossible above is what lazily builds the current page's player,
    // so the transport can only bind after the loop. Nil player (still image,
    // or a hosted clip whose lookup is in flight) shows the bar disabled.
    [self apollo_bindVideoBarToPlayer:[self apollo_currentCell].player];
}

- (void)apollo_prefetchAroundIndex:(NSInteger)index {
    NSInteger radius = self.prefetchRadius;

    // Paging moved the window: transfers warming pages now outside it are
    // spent bandwidth and decode pressure, so stop them instead of letting
    // them run to completion behind the user.
    NSMutableArray<NSNumber *> *stale = [NSMutableArray array];
    [self.viewerPrefetches enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, ApolloGalleryImageRequest *request, BOOL *stop) {
        if (llabs(key.integerValue - index) > radius) {
            [request cancel];
            [stale addObject:key];
        }
    }];
    [self.viewerPrefetches removeObjectsForKeys:stale];

    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    for (NSInteger offset = -radius; offset <= radius; offset++) {
        NSInteger neighbour = index + offset;
        if (offset == 0 || neighbour < 0 || neighbour >= (NSInteger)items.count) continue;
        if (self.viewerPrefetches[@(neighbour)]) continue;
        ApolloGalleryImageRequest *request =
            [[ApolloGalleryImageLoader sharedLoader] prefetchImageAtURL:items[neighbour].imageURL];
        if (request) self.viewerPrefetches[@(neighbour)] = request;
    }
}

- (void)apollo_loadMoreIfNeeded {
    NSInteger total = (NSInteger)self.feed.items.count;
    if (self.feed.isExhausted || self.feed.isLoading) return;
    if (self.currentIndex < total - kApolloGalleryViewerLoadAheadSlack) return;

    [self apollo_setStatus:@"Loading more…"];
    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf apollo_setStatus:nil];
        if (errorMessage.length > 0) {
            [strongSelf apollo_showToast:@"Couldn't load more"];
            return;
        }
        if (addedRange.length == 0) {
            if (strongSelf.feed.isExhausted) [strongSelf apollo_showToast:@"That's everything"];
            return;
        }
        [strongSelf feedDidAppendItems];
        id<ApolloGalleryImageViewerDelegate> delegate = strongSelf.galleryDelegate;
        if ([delegate respondsToSelector:@selector(galleryViewer:didAppendItemsInRange:)]) {
            [delegate galleryViewer:strongSelf didAppendItemsInRange:addedRange];
        }
    }];
}

// Appends are derived by diffing the collection view's committed count against
// the feed rather than trusting a callback range — the counts are the truth,
// and a stale range (a filter/sort change landing mid-batch) then can't be
// inserted. Appending past the end never disturbs the visible page's offset,
// so this is safe mid-swipe.
- (void)feedDidAppendItems {
    if (!self.isViewLoaded) return;
    NSInteger known = [self.collectionView numberOfItemsInSection:0];
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total <= known) return;
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)(total - known)];
    for (NSInteger i = known; i < total; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
    }
    [self.collectionView performBatchUpdates:^{
        [self.collectionView insertItemsAtIndexPaths:indexPaths];
    } completion:nil];
    [self apollo_updateChromeContent];
}

#pragma mark Gestures

- (void)apollo_singleTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    [self apollo_setChromeVisible:!self.chromeVisible animated:YES];
}

- (void)apollo_longPressed:(UILongPressGestureRecognizer *)recognizer {
    AVPlayer *player = self.observedPlayer;
    NSTimeInterval duration = [self apollo_currentVideoDuration];
    BOOL scrubbable = [self apollo_currentItem].playsAsVideo && player && duration > 0.0;

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            if (!scrubbable) {
                // Still pictures keep the original hold-for-actions.
                [self apollo_presentActionsFromView:self.view];
                return;
            }
            // Arm, but don't commit: a hold that never moves is still the
            // actions sheet (on release), so the old gesture isn't lost.
            self.gestureScrubArmed = YES;
            self.gestureScrubActive = NO;
            self.gestureScrubStartX = [recognizer locationInView:self.view].x;
            self.gestureScrubStartTime = CMTimeGetSeconds(player.currentTime);
            if (!isfinite(self.gestureScrubStartTime) || self.gestureScrubStartTime < 0.0) {
                self.gestureScrubStartTime = 0.0;
            }
            // Same trick the dismiss pan uses: kills any paging drag UIKit
            // had started on this touch, so the horizontal scrub can't also
            // turn the page.
            self.collectionView.scrollEnabled = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.gestureScrubArmed || !scrubbable) return;
            CGFloat deltaX = [recognizer locationInView:self.view].x - self.gestureScrubStartX;
            if (!self.gestureScrubActive) {
                if (fabs(deltaX) < 12.0) return;   // slop: not a scrub yet
                self.gestureScrubActive = YES;
                self.videoScrubbing = YES;         // periodic observer hands off
                self.gestureScrubWasPlaying = player.rate > 0.0f;
                [player pause];
            }
            // A full-width drag sweeps the whole clip, matching the slider's
            // scale, so the two ways of scrubbing feel like one control.
            CGFloat width = MAX(self.view.bounds.size.width, 1.0);
            NSTimeInterval target = self.gestureScrubStartTime + (deltaX / width) * duration;
            target = MAX(0.0, MIN(target, MAX(duration - 0.1, 0.0)));
            self.videoSlider.value = (float)(target / duration);
            self.currentTimeLabel.text = ApolloGalleryTimeString(target);
            [self apollo_scrubSeekToSeconds:target];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            BOOL wasArmed = self.gestureScrubArmed;
            BOOL wasActive = self.gestureScrubActive;
            self.gestureScrubArmed = NO;
            self.gestureScrubActive = NO;
            if (!wasArmed) return;
            self.collectionView.scrollEnabled = YES;
            if (!wasActive) {
                // Held without dragging: the original actions sheet.
                if (recognizer.state == UIGestureRecognizerStateEnded) {
                    [self apollo_presentActionsFromView:self.view];
                }
                return;
            }
            NSTimeInterval target = self.videoSlider.value * duration;
            target = MIN(target, MAX(duration - 0.1, 0.0));
            BOOL resume = self.gestureScrubWasPlaying;
            // The precise landing seek supersedes anything still coalescing.
            self.videoHasPendingSeek = NO;
            __weak typeof(self) weakSelf = self;
            [player seekToTime:CMTimeMakeWithSeconds(target, 600)
               toleranceBefore:kCMTimeZero
                toleranceAfter:kCMTimeZero
             completionHandler:^(BOOL finished) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    strongSelf.videoScrubbing = NO;
                    if (resume) [[strongSelf apollo_currentCell] playIfPossible];
                    [strongSelf apollo_refreshVideoBarNow];
                });
                (void)finished;
            }];
            break;
        }
        default:
            break;
    }
}

- (ApolloGalleryViewerCell *)apollo_currentCell {
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:self.currentIndex inSection:0];
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
    return [cell isMemberOfClass:[ApolloGalleryViewerCell class]] ? (ApolloGalleryViewerCell *)cell : nil;
}

- (void)apollo_dismissPanned:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.view];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            // Toggling scrollEnabled cancels any paging drag UIKit had started
            // on the same touch, so a diagonal flick can't page AND dismiss.
            self.collectionView.scrollEnabled = NO;
                    [UIView animateWithDuration:0.15 animations:^{
                self.doneHost.alpha = 0.0;
                self.shareHost.alpha = 0.0;
                self.muteHost.alpha = 0.0;
                self.counterPill.alpha = 0.0;
                self.infoPanel.alpha = 0.0;
                self.videoBarPill.alpha = 0.0;
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat progress = MIN(fabs(translation.y) / 400.0, 1.0);
            self.collectionView.transform = CGAffineTransformMakeTranslation(0.0, translation.y);
            self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0 - progress * 0.65];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat velocity = [recognizer velocityInView:self.view].y;
            BOOL commit = recognizer.state == UIGestureRecognizerStateEnded &&
                          (fabs(translation.y) > kApolloGalleryViewerDismissDistance ||
                           fabs(velocity) > kApolloGalleryViewerDismissVelocity);
            if (commit) {
                // Keep flying in the direction the finger was already going.
                CGFloat direction = (translation.y != 0.0 ? translation.y : velocity) < 0.0 ? -1.0 : 1.0;
                [self apollo_dismissWithFlickDirection:direction];
            } else {
                self.collectionView.scrollEnabled = YES;
                [UIView animateWithDuration:0.28
                                      delay:0.0
                     usingSpringWithDamping:0.85
                      initialSpringVelocity:0.0
                                    options:UIViewAnimationOptionAllowUserInteraction
                                 animations:^{
                    self.collectionView.transform = CGAffineTransformIdentity;
                    self.view.backgroundColor = UIColor.blackColor;
                } completion:nil];
                [self apollo_setChromeVisible:self.chromeVisible animated:YES];
            }
            break;
        }
        default:
            break;
    }
}

- (void)apollo_dismissWithFlickDirection:(CGFloat)direction {
    if (self.isDismissing) return;
    self.isDismissing = YES;
    [self apollo_notifyWillDismiss];
    CGFloat offscreen = direction * (self.view.bounds.size.height + 80.0);
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.collectionView.transform = CGAffineTransformMakeTranslation(0.0, offscreen);
        self.view.backgroundColor = UIColor.clearColor;
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)apollo_notifyWillDismiss {
    id<ApolloGalleryImageViewerDelegate> delegate = self.galleryDelegate;
    if ([delegate respondsToSelector:@selector(galleryViewer:willDismissAtIndex:)]) {
        [delegate galleryViewer:self willDismissAtIndex:self.currentIndex];
    }
}

- (void)apollo_donePressed {
    if (self.isDismissing) return;
    self.isDismissing = YES;
    [self apollo_notifyWillDismiss];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.dismissPan) return YES;
    // A zoomed-in page pans its own content instead.
    if ([self apollo_currentCell].isZoomed) return NO;
    // A hold-scrub in progress owns the drag; a stray vertical drift must not
    // start dismissing (which would cancel the scrub mid-gesture).
    if (self.gestureScrubArmed || self.gestureScrubActive) return NO;
    CGPoint velocity = [self.dismissPan velocityInView:self.view];
    return fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // The card's own tap (open post) must not fire when the touch is on its
    // × — that button dismisses the card instead.
    if (gestureRecognizer == self.infoTap) {
        return ![touch.view isDescendantOfView:self.infoCloseButton];
    }
    // Let the info panel's own tap handle taps that land on it.
    if ([touch.view isDescendantOfView:self.infoPanel] && self.chromeVisible) {
        return ![gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]];
    }
    // The transport bar owns every touch that starts on it: a scrub must
    // never toggle the chrome, page, or start the dismiss pan (which would
    // cancel the slider's tracking mid-drag).
    if ([touch.view isDescendantOfView:self.videoBarPill] && self.chromeVisible) {
        return NO;
    }
    return YES;
}

#pragma mark Actions

- (ApolloGalleryItem *)apollo_currentItem {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)items.count) return nil;
    return items[self.currentIndex];
}

// The mute control only makes sense on a page that can make noise.
- (void)apollo_updateMuteButton {
    ApolloGalleryItem *item = [self apollo_currentItem];
    BOOL showsMute = item.playsAsVideo && item.kind == ApolloGalleryMediaKindVideo;
    self.muteHost.hidden = !showsMute;
    if (showsMute) {
        BOOL muted = ApolloGalleryViewerVideosMuted();
        [self.muteButton setImage:ApolloGalleryChromeSymbol(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill")
                         forState:UIControlStateNormal];
        self.muteButton.accessibilityLabel = muted ? @"Unmute" : @"Mute";
        self.muteHost.alpha = self.chromeVisible ? 1.0 : 0.0;
    }
    [self.view setNeedsLayout];
}

- (void)apollo_muteTapped {
    ApolloGalleryViewerSetVideosMuted(!ApolloGalleryViewerVideosMuted());
    [self apollo_syncPlayback];
}

- (void)apollo_infoPanelTapped {
    [self apollo_openCurrentPost];
}

- (void)apollo_hideInfoPanelTapped {
    [self apollo_setInfoPanelHidden:YES];
}

- (void)apollo_setInfoPanelHidden:(BOOL)hidden {
    if (self.infoPanelHiddenForItem == hidden) return;
    self.infoPanelHiddenForItem = hidden;
    // Rebuilds the share menu so its row reads the other way round now.
    [self apollo_updateChromeContent];
    [UIView animateWithDuration:0.2 animations:^{
        [self.view layoutIfNeeded];
    }];
}

// The share button's actions as a UIMenu. Same set as the long-press sheet;
// as a menu it gets the iOS 26 morph out of the button for free, and on older
// releases it's still a native menu rather than a modal sheet.
- (UIMenu *)apollo_buildActionsMenu {
    ApolloGalleryItem *item = [self apollo_currentItem];
    if (!item) return [UIMenu menuWithTitle:@"" children:@[]];

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];

    if (item.playsAsVideo) {
        if (item.videoDownloadURL) {
            [children addObject:[UIAction actionWithTitle:@"Save Video"
                                                    image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                               identifier:nil
                                                  handler:^(__kindof UIAction *a) { [weakSelf apollo_saveCurrentVideo]; }]];
        }
        NSURL *shareURL = item.videoURL ?: item.hostedVideoPageURL;
        if (shareURL) {
            [children addObject:[UIAction actionWithTitle:@"Share Video Link"
                                                    image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                               identifier:nil
                                                  handler:^(__kindof UIAction *a) {
                [weakSelf apollo_presentActivityWithItems:@[shareURL] fromView:weakSelf.shareButton];
            }]];
        }
    } else {
        [children addObject:[UIAction actionWithTitle:@"Save Image"
                                                image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) { [weakSelf apollo_saveCurrentImage]; }]];
        [children addObject:[UIAction actionWithTitle:@"Share Image"
                                                image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) {
            [weakSelf apollo_shareCurrentImageFromView:weakSelf.shareButton];
        }]];
    }
    if (item.postURL) {
        [children addObject:[UIAction actionWithTitle:@"Share Post Link"
                                                image:[UIImage systemImageNamed:@"link"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) {
            [weakSelf apollo_sharePostLinkFromView:weakSelf.shareButton];
        }]];
        [children addObject:[UIAction actionWithTitle:@"Open Post"
                                                image:[UIImage systemImageNamed:@"arrow.up.right.square"]
                                           identifier:nil
                                              handler:^(__kindof UIAction *a) { [weakSelf apollo_openCurrentPost]; }]];
    }
    // The way back from the card's × (and the way to dismiss it without
    // hunting for that button).
    BOOL infoHidden = self.infoPanelHiddenForItem;
    [children addObject:[UIAction actionWithTitle:(infoHidden ? @"Show Post Info" : @"Hide Post Info")
                                            image:[UIImage systemImageNamed:(infoHidden ? @"info.circle" : @"info.circle.fill")]
                                       identifier:nil
                                          handler:^(__kindof UIAction *a) {
        [weakSelf apollo_setInfoPanelHidden:!infoHidden];
    }]];
    return [UIMenu menuWithTitle:item.postTitle ?: @"" children:children];
}

- (void)apollo_presentActionsFromView:(UIView *)sourceView {
    ApolloGalleryItem *item = [self apollo_currentItem];
    if (!item) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.postTitle
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (item.playsAsVideo) {
        if (item.videoDownloadURL) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Save Video" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [weakSelf apollo_saveCurrentVideo];
            }]];
        }
        NSURL *shareURL = item.videoURL ?: item.hostedVideoPageURL;
        if (shareURL) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Share Video Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [weakSelf apollo_presentActivityWithItems:@[shareURL] fromView:sourceView];
            }]];
        }
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Save Image" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_saveCurrentImage];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Image" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_shareCurrentImageFromView:sourceView];
        }]];
    }
    if (item.postURL) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Post Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_sharePostLinkFromView:sourceView];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Open Post" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_openCurrentPost];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = (sourceView && sourceView != self.view)
            ? sourceView.bounds
            : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// Original bytes when we still have them (a GIF stays animated), otherwise a
// PNG re-encode of the on-screen image — but ONLY once the full-size image is
// the thing on screen. While the full load is still in flight the image view
// is showing the grid's downsampled thumbnail, and exporting that would
// silently save a low-res copy; returning nil instead routes the action to
// the "Still loading" toast.
- (NSData *)apollo_dataForCurrentItem {
    ApolloGalleryItem *item = [self apollo_currentItem];
    if (!item) return nil;
    NSData *data = [[ApolloGalleryImageLoader sharedLoader] cachedDataForURL:item.imageURL];
    if (data.length > 0) return data;
    ApolloGalleryViewerCell *cell = [self apollo_currentCell];
    if (!cell.fullImageLoaded) return nil;
    UIImage *image = cell.imageView.image;
    return image ? UIImagePNGRepresentation(image) : nil;
}

- (void)apollo_saveCurrentImage {
    NSData *data = [self apollo_dataForCurrentItem];
    if (data.length == 0) {
        [self apollo_showToast:@"Still loading"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^performSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [weakSelf apollo_showToast:@"Saved"];
                } else {
                    ApolloLog(@"[Gallery] save failed: %@", error.localizedDescription);
                    [weakSelf apollo_showToast:@"Save failed"];
                }
            });
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                    performSave();
                } else {
                    [weakSelf apollo_showToast:@"Photos access denied"];
                }
            });
        }];
    } else if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        performSave();
    } else {
        [self apollo_showToast:@"Photos access denied"];
    }
}

// Handed off to ApolloGalleryVideoExport, which knows that a v.redd.it save
// needs the separate DASH audio muxed back in before it's worth keeping.
- (void)apollo_saveCurrentVideo {
    NSURL *source = [self apollo_currentItem].videoDownloadURL;
    if (!source) return;

    __weak typeof(self) weakSelf = self;
    ApolloGallerySaveVideoToPhotos(source, ^(NSString *text) {
        [weakSelf apollo_showToast:text];
    }, ^(BOOL success, NSString *message) {
        [weakSelf apollo_showToast:message];
    });
}

- (void)apollo_shareCurrentImageFromView:(UIView *)sourceView {
    ApolloGalleryItem *item = [self apollo_currentItem];
    NSData *data = [self apollo_dataForCurrentItem];
    NSArray *activityItems = nil;

    if (data.length > 0) {
        // Write with the source filename so the receiving app sees a real .gif
        // / .jpg rather than a generic blob.
        NSString *name = item.imageURL.lastPathComponent.length > 0
            ? item.imageURL.lastPathComponent
            : [NSString stringWithFormat:@"image-%ld.jpg", (long)self.currentIndex + 1];
        NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        if ([data writeToURL:fileURL atomically:YES]) activityItems = @[fileURL];
    }
    if (!activityItems && item.imageURL) activityItems = @[item.imageURL];
    if (!activityItems) {
        [self apollo_showToast:@"Still loading"];
        return;
    }
    [self apollo_presentActivityWithItems:activityItems fromView:sourceView];
}

- (void)apollo_sharePostLinkFromView:(UIView *)sourceView {
    NSURL *postURL = [self apollo_currentItem].postURL;
    if (!postURL) return;
    [self apollo_presentActivityWithItems:@[postURL] fromView:sourceView];
}

- (void)apollo_presentActivityWithItems:(NSArray *)activityItems fromView:(UIView *)sourceView {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:activityItems
                                                                           applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = (sourceView && sourceView != self.view)
            ? sourceView.bounds
            : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

// Hand off to Apollo's own post view. The viewer has to get out of the way
// first: routing a URL while a fullscreen modal is up would push the post
// behind it.
- (void)apollo_openCurrentPost {
    NSURL *postURL = [self apollo_currentItem].postURL;
    if (!postURL) return;
    if (!self.isDismissing) {
        self.isDismissing = YES;
        [self apollo_notifyWillDismiss];
    }
    [self dismissViewControllerAnimated:YES completion:^{
        // Apollo's URL handler only acts on apollo:// URLs — handing it the raw
        // https reddit.com link is silently ignored. The scheme conversion is
        // what every other in-app route in the tweak goes through.
        if (ApolloRouteResolvedURLViaApolloScheme(postURL)) return;
        if (!ApolloRouteURLThroughApp(postURL)) {
            ApolloLog(@"[Gallery] couldn't route %@ through the app", postURL.absoluteString);
        }
    }];
}

@end
