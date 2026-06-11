#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloState.h"
#import "ApolloMediaMetadata.h"
#import "ApolloMarkdownToolbarGif.h"
#import "Tweak.h"

// FFmpegKit's static libs are device-arm64 only, so simulator/dev builds
// (APOLLO_SIM_BUILD, see Makefile + scripts/run-in-sim.sh) compile without it.
// The v.redd.it CMAF/MPEG-TS audio fix below is stubbed to %orig in that mode.
#if !APOLLO_SIM_BUILD
#import "ffmpeg-kit/ffmpeg-kit/include/MediaInformationSession.h"
#import "ffmpeg-kit/ffmpeg-kit/include/MediaInformation.h"
#import "ffmpeg-kit/ffmpeg-kit/include/FFmpegKit.h"
#import "ffmpeg-kit/ffmpeg-kit/include/FFprobeKit.h"
#endif

// Regex patterns for v.redd.it CMAF audio streams (Reddit switched from MPEG-TS to CMAF around November 2025)
static NSString *const HLSAudioRegexPattern = @"#EXT-X-MEDIA:.*?\"(HLS_AUDIO.*?)\\.m3u8";
static NSString *const CMAFAudioRegexPattern = @"#EXT-X-MEDIA:.*?\"((?:HLS|CMAF)_AUDIO.*?)\\.m3u8";
static NSString *const CMAFAudioIdentifier = @"CMAF_AUDIO";

// Regex patterns for Streamable URLs (some Streamable links have new query strings)
static NSString *const StreamableRegexPattern = @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)$";
static NSString *const StreamableRegexPatternWithQueryString = @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)(?:\\?.*)?$";

static const void *kApolloRouteIconRepairLoggedKey = &kApolloRouteIconRepairLoggedKey;
static const void *kApolloRouteButtonStyleLoggedKey = &kApolloRouteButtonStyleLoggedKey;

static BOOL ApolloMediaStringContains(NSString *haystack, NSString *needle) {
    return [haystack isKindOfClass:[NSString class]] && needle.length > 0 &&
        [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL ApolloMediaViewIsInClassNamed(UIView *view, NSString *needle) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (ApolloMediaStringContains(NSStringFromClass(responder.class), needle)) return YES;
    }
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ApolloMediaStringContains(NSStringFromClass(ancestor.class), needle)) return YES;
    }
    return NO;
}

static BOOL ApolloMediaRouteControlIsInMediaViewer(UIView *view) {
    return ApolloMediaViewIsInClassNamed(view, @"MediaViewer") ||
        ApolloMediaViewIsInClassNamed(view, @"MediaPage") ||
        ApolloMediaViewIsInClassNamed(view, @"Player") ||
        ApolloMediaViewIsInClassNamed(view, @"VideoControlsView");
}

static void ApolloMediaClearRouteButtonLayer(CALayer *layer, CALayer *primaryImageLayer) {
    if (!layer) return;

    layer.masksToBounds = NO;
    layer.cornerRadius = 0.0;
    layer.borderWidth = 0.0;
    layer.shadowOpacity = 0.0;
    if (layer != primaryImageLayer) layer.backgroundColor = nil;

    for (CALayer *sublayer in layer.sublayers) {
        ApolloMediaClearRouteButtonLayer(sublayer, primaryImageLayer);
    }
}

static void ApolloMediaStyleVideoControlsAirPlayButton(UIButton *button, NSString *reason) {
    if (![button isKindOfClass:[UIButton class]] || !ApolloMediaViewIsInClassNamed(button, @"VideoControlsView")) return;

    UIImage *airPlayImage = [[UIImage imageNamed:@"video-player-airplay"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!airPlayImage) return;

    if ([button respondsToSelector:@selector(setConfiguration:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, @selector(setConfiguration:), nil);
    }
    if ([button respondsToSelector:@selector(setConfigurationUpdateHandler:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, @selector(setConfigurationUpdateHandler:), nil);
    }

    const UIControlState states[] = {
        UIControlStateNormal,
        UIControlStateHighlighted,
        UIControlStateSelected,
        UIControlStateSelected | UIControlStateHighlighted,
        UIControlStateDisabled,
        UIControlStateFocused,
        UIControlStateSelected | UIControlStateFocused,
        UIControlStateApplication,
        UIControlStateSelected | UIControlStateApplication,
    };
    for (NSUInteger i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
        [button setImage:airPlayImage forState:states[i]];
        [button setBackgroundImage:nil forState:states[i]];
    }

    BOOL activeRoute = button.selected || ((button.state & UIControlStateSelected) == UIControlStateSelected);
    if (activeRoute) {
        button.tintColor = [UIColor respondsToSelector:@selector(systemBlueColor)] ? [UIColor systemBlueColor] : [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
    } else {
        button.tintColor = [UIColor whiteColor];
    }

    button.backgroundColor = [UIColor clearColor];
    button.adjustsImageWhenHighlighted = NO;
    button.showsTouchWhenHighlighted = NO;
    button.clipsToBounds = NO;
    button.contentMode = UIViewContentModeScaleAspectFit;
    button.imageView.hidden = NO;
    button.imageView.image = airPlayImage;
    button.imageView.highlightedImage = airPlayImage;
    button.imageView.tintColor = button.tintColor;
    button.imageView.backgroundColor = [UIColor clearColor];
    button.imageView.clipsToBounds = NO;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;

    for (UIView *subview in button.subviews) {
        subview.backgroundColor = [UIColor clearColor];
        subview.clipsToBounds = NO;
        subview.layer.masksToBounds = NO;
        if ([subview isKindOfClass:[UIImageView class]] && subview != button.imageView) {
            subview.hidden = YES;
        }
    }
    ApolloMediaClearRouteButtonLayer(button.layer, button.imageView.layer);

    if (objc_getAssociatedObject(button, kApolloRouteButtonStyleLoggedKey) == nil) {
        objc_setAssociatedObject(button, kApolloRouteButtonStyleLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[MediaRouteIcon] styled VideoControlsView AirPlay button class=%@ state=%lu reason=%@", NSStringFromClass(button.class) ?: @"(unknown)", (unsigned long)button.state, reason ?: @"(unknown)");
    }
}

static void ApolloMediaRepairRouteControlLayout(UIView *routeView, NSString *reason) {
    if (![routeView isKindOfClass:[UIView class]] || !ApolloMediaRouteControlIsInMediaViewer(routeView)) return;
    routeView.clipsToBounds = NO;
    routeView.contentMode = UIViewContentModeScaleAspectFit;
    routeView.layer.masksToBounds = NO;
    routeView.superview.clipsToBounds = NO;
    routeView.superview.layer.masksToBounds = NO;

    CGRect frame = routeView.frame;
    CGFloat minSide = 36.0;
    if (frame.size.width > 0.0 && frame.size.width < minSide) frame.size.width = minSide;
    if (frame.size.height > 0.0 && frame.size.height < minSide) frame.size.height = minSide;
    routeView.frame = frame;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:routeView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 80) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        view.clipsToBounds = NO;
        view.layer.masksToBounds = NO;
        view.contentMode = UIViewContentModeScaleAspectFit;
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            ApolloMediaStyleVideoControlsAirPlayButton(button, reason);
        } else if ([view isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)view).contentMode = UIViewContentModeScaleAspectFit;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }

    if (objc_getAssociatedObject(routeView, kApolloRouteIconRepairLoggedKey) == nil) {
        objc_setAssociatedObject(routeView, kApolloRouteIconRepairLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[MediaRouteIcon] repaired route control layout class=%@ frame=%@ reason=%@", NSStringFromClass(routeView.class) ?: @"(unknown)", NSStringFromCGRect(routeView.frame), reason ?: @"(unknown)");
    }
}

%hook AVRoutePickerView

- (void)layoutSubviews {
    %orig;
    ApolloMediaRepairRouteControlLayout((UIView *)self, @"AVRoutePickerView layoutSubviews");
}

%end

%hook MPVolumeView

- (void)layoutSubviews {
    %orig;
    ApolloMediaRepairRouteControlLayout((UIView *)self, @"MPVolumeView layoutSubviews");
}

%end

%hook _TtC6Apollo17VideoControlsView

- (void)layoutSubviews {
    %orig;
    UIButton *airPlayButton = MSHookIvar<UIButton *>(self, "airPlayButton");
    ApolloMediaStyleVideoControlsAirPlayButton(airPlayButton, @"VideoControlsView layoutSubviews");
}

- (void)observeValueForKeyPath:(id)keyPath ofObject:(id)object change:(id)change context:(void *)context {
    %orig(keyPath, object, change, context);
    UIButton *airPlayButton = MSHookIvar<UIButton *>(self, "airPlayButton");
    ApolloMediaStyleVideoControlsAirPlayButton(airPlayButton, @"VideoControlsView KVO");
}

%end

// Implementation derived from https://github.com/dankrichtofen/apolloliquidglass/blob/main/Tweak.x
// Credits to @dankrichtofen for the original implementation
%hook ASImageNode

+ (UIImage *)createContentsForkey:(id)key drawParameters:(id)parameters isCancelled:(id)cancelled {
    @try {
        UIImage *result = %orig;
        return result;
    }
    @catch (NSException *exception) {
        return nil;
    }
}

%end

// Fix GIF looping playback speed on 120Hz ProMotion displays
// Implementation derived from https://github.com/Flipboard/FLAnimatedImage/pull/266
// Credits to @yoshimura-qcul for the original fix
%hook FLAnimatedImageView

- (void)setAnimatedImage:(FLAnimatedImage *)animatedImage {
    %orig;
    ApolloApplyFLAnimatedImageViewAutoplayGate(self);
}

- (void)startAnimating {
    if (ApolloViewIsInlineGIF(self) && !ApolloInlineGIFViewShouldAutoplay(self)) {
        MSHookIvar<BOOL>(self, "_shouldAnimate") = NO;
        return;
    }
    %orig;
}

- (void)displayDidRefresh:(CADisplayLink *)displayLink {
    // Get required ivars
    FLAnimatedImage *animatedImage = MSHookIvar<FLAnimatedImage *>(self, "_animatedImage");
    if (!animatedImage) {
        return;
    }

    if (ApolloViewIsInlineGIF(self) && !ApolloInlineGIFViewShouldAutoplay(self)) {
        MSHookIvar<BOOL>(self, "_shouldAnimate") = NO;
        return;
    }

    BOOL shouldAnimate = MSHookIvar<BOOL>(self, "_shouldAnimate");
    if (!shouldAnimate) {
        return;
    }

    NSDictionary *delayTimesForIndexes = [animatedImage delayTimesForIndexes];
    NSUInteger currentFrameIndex = MSHookIvar<NSUInteger>(self, "_currentFrameIndex");
    NSNumber *delayTimeNumber = [delayTimesForIndexes objectForKey:@(currentFrameIndex)];

    if (delayTimeNumber != nil) {
        NSTimeInterval delayTime = [delayTimeNumber doubleValue];
        UIImage *image = [animatedImage imageLazilyCachedAtIndex:currentFrameIndex];

        if (image) {
            MSHookIvar<UIImage *>(self, "_currentFrame") = image;

            BOOL needsDisplay = MSHookIvar<BOOL>(self, "_needsDisplayWhenImageBecomesAvailable");
            if (needsDisplay) {
                [self.layer setNeedsDisplay];
                MSHookIvar<BOOL>(self, "_needsDisplayWhenImageBecomesAvailable") = NO;
            }

            // Fix for 120Hz displays: use preferredFramesPerSecond instead of duration * frameInterval
            double *accumulatorPtr = &MSHookIvar<double>(self, "_accumulator");
            if (@available(iOS 10.0, *)) {
                NSInteger preferredFPS = displayLink.preferredFramesPerSecond;
                if (preferredFPS > 0) {
                    *accumulatorPtr += 1.0 / (double)preferredFPS;
                } else {
                    *accumulatorPtr += displayLink.duration;
                }
            } else {
                *accumulatorPtr += displayLink.duration;
            }

            NSUInteger frameCount = [animatedImage frameCount];
            NSUInteger loopCount = [animatedImage loopCount];

            while (*accumulatorPtr >= delayTime) {
                *accumulatorPtr -= delayTime;
                MSHookIvar<NSUInteger>(self, "_currentFrameIndex")++;

                if (MSHookIvar<NSUInteger>(self, "_currentFrameIndex") >= frameCount) {
                    MSHookIvar<NSUInteger>(self, "_loopCountdown")--;

                    void (^loopCompletionBlock)(NSUInteger) = MSHookIvar<void (^)(NSUInteger)>(self, "_loopCompletionBlock");
                    if (loopCompletionBlock) {
                        loopCompletionBlock(MSHookIvar<NSUInteger>(self, "_loopCountdown"));
                    }

                    if (MSHookIvar<NSUInteger>(self, "_loopCountdown") == 0 && loopCount > 0) {
                        [self stopAnimating];
                        return;
                    }
                    MSHookIvar<NSUInteger>(self, "_currentFrameIndex") = 0;
                }
                MSHookIvar<BOOL>(self, "_needsDisplayWhenImageBecomesAvailable") = YES;
            }
        } else {
            MSHookIvar<BOOL>(self, "_needsDisplayWhenImageBecomesAvailable") = YES;
        }
    } else {
        MSHookIvar<NSUInteger>(self, "_currentFrameIndex")++;
    }
}

%end

// Fix MP4 GIF loop freeze in MediaViewerController fullscreen player
//
// Stock Apollo bug: on every loop boundary, the didPlayToEnd handler
// (sub_10036da80) dispatches two `seekToTime:kCMTimeZero` calls ~1 ms apart
// from sibling DispatchQueue.main.async blocks. The second seek interrupts
// the first mid-flight, double-resetting the decode pipeline and causing a
// ~0.5–1.5s freeze at a random mid-video frame on every loop after the first.
//
// Scoping: `-[AVPlayer setActionAtItemEnd:]` has exactly one xref in Apollo
// (inside createPlayer(withURL:) at sub_100363c90, called with
// AVPlayerActionAtItemEndNone). We use that single call as a tag for the
// MediaViewer non-shareable player; shareable v.redd.it, comments header,
// and feed cell players leave actionAtItemEnd at its default and are not
// touched. Fix: on tagged players, dedupe seek-to-zero calls within a
// 250 ms window — first call goes through to %orig, subsequent ones invoke
// only their completionHandler so caller state machinery still runs.
static const void *kApolloGifLoopFixKey = &kApolloGifLoopFixKey;
static const void *kApolloGifLoopLastSeekKey = &kApolloGifLoopLastSeekKey;
static const void *kApolloGifLoopDedupeLoggedKey = &kApolloGifLoopDedupeLoggedKey;
static const NSTimeInterval kApolloGifLoopSeekDedupeWindow = 0.25;

%hook AVPlayer

- (void)setActionAtItemEnd:(AVPlayerActionAtItemEnd)action {
    %orig;
    if (action == AVPlayerActionAtItemEndNone) {
        if (objc_getAssociatedObject(self, kApolloGifLoopFixKey) != nil) {
            return;
        }
        objc_setAssociatedObject(self, kApolloGifLoopFixKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[GifLoopFix] Marked AVPlayer %p (actionAtItemEnd=None)", self);
    }
}

- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)toleranceBefore toleranceAfter:(CMTime)toleranceAfter completionHandler:(void (^)(BOOL))completionHandler {
    BOOL isLoopFixPlayer = (objc_getAssociatedObject(self, kApolloGifLoopFixKey) != nil);
    BOOL isZeroSeek = CMTIME_IS_VALID(time) && CMTimeCompare(time, kCMTimeZero) == 0;

    if (isLoopFixPlayer && isZeroSeek) {
        NSTimeInterval now = CACurrentMediaTime();
        NSNumber *lastSeek = objc_getAssociatedObject(self, kApolloGifLoopLastSeekKey);
        NSTimeInterval delta = lastSeek ? (now - lastSeek.doubleValue) : INFINITY;

        if (delta < kApolloGifLoopSeekDedupeWindow) {
            // Sibling seek from same didPlayToEnd handler — skip %orig but
            // still invoke completionHandler so caller state logic runs.
            if (objc_getAssociatedObject(self, kApolloGifLoopDedupeLoggedKey) == nil) {
                objc_setAssociatedObject(self, kApolloGifLoopDedupeLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[GifLoopFix] Deduping sibling seek-to-zero on %p (%.1fms after first); will suppress further per-loop logs",
                          self, delta * 1000.0);
            }
            if (completionHandler) {
                void (^handler)(BOOL) = [completionHandler copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler(YES);
                });
            }
            return;
        }

        objc_setAssociatedObject(self, kApolloGifLoopLastSeekKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end


%hook NSRegularExpression

- (instancetype)initWithPattern:(NSString *)pattern options:(NSRegularExpressionOptions)options error:(NSError **)error {
    // Around November 2025, Reddit started using CMAF instead of MPEG-TS for audio streams (v.redd.it).
    // Apollo's regex only matches HLS_AUDIO naming pattern, so update to also match CMAF_AUDIO
    if ([pattern isEqualToString:HLSAudioRegexPattern]) {
        return %orig(CMAFAudioRegexPattern, options, error);
    }
    // Handle newer Streamable links with query strings like "?src=player-page-share"
    if ([pattern isEqualToString:StreamableRegexPattern]) {
        return %orig(StreamableRegexPatternWithQueryString, options, error);
    }
    return %orig;
}

- (NSArray<NSTextCheckingResult *> *)matchesInString:(NSString *)string options:(NSMatchingOptions)options range:(NSRange)range {
    NSArray *results = %orig;

    // CMAF manifests list audio in descending bitrate order:
    //   #EXT-X-MEDIA:URI="CMAF_AUDIO_128.m3u8",...
    //   #EXT-X-MEDIA:URI="CMAF_AUDIO_64.m3u8",...
    // but Apollo expects ascending order (how older MPEG-TS streams were ordered),
    // so we need to reorder the results so Apollo downloads the highest quality audio.
    if (results.count >= 2 && [self.pattern isEqualToString:CMAFAudioRegexPattern]) {
        // Sort by extracting bitrate number from captured text
        results = [results sortedArrayUsingComparator:^NSComparisonResult(NSTextCheckingResult *result1, NSTextCheckingResult *result2) {
            if (result1.numberOfRanges > 1 && result2.numberOfRanges > 1) {
                NSString *text1 = [string substringWithRange:[result1 rangeAtIndex:1]];
                NSString *text2 = [string substringWithRange:[result2 rangeAtIndex:1]];

                // Use NSScanner to extract first integer from each string
                NSScanner *scanner1 = [NSScanner scannerWithString:text1];
                NSScanner *scanner2 = [NSScanner scannerWithString:text2];
                NSInteger bitrate1 = 0, bitrate2 = 0;

                [scanner1 scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                [scanner1 scanInteger:&bitrate1];
                [scanner2 scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:nil];
                [scanner2 scanInteger:&bitrate2];

                return [@(bitrate1) compare:@(bitrate2)];
            }
            return NSOrderedSame;
        }];
    }
    return results;
}

%end

%hook NSURLRequest

+ (instancetype)requestWithURL:(NSURL *)URL {
    // Fix CMAF audio URLs: Apollo tries to download .aac but CMAF uses .mp4
    if ([URL.pathExtension isEqualToString:@"aac"] && [URL.absoluteString containsString:CMAFAudioIdentifier]) {
        NSURL *fixedURL = [[URL URLByDeletingPathExtension] URLByAppendingPathExtension:@"mp4"];
        ApolloLog(@"[NSURLRequest] Fixed CMAF audio URL: %@ -> %@", URL.absoluteString, fixedURL.absoluteString);
        return %orig(fixedURL);
    }
    return %orig;
}

%end

%hook _TtC6Apollo17ShareMediaManager

// Patches to fix audio container formats for v.redd.it videos:
// - Some streams use MPEG-TS containers (fix: convert to ADTS)
// - Newer streams use CMAF/MP4 containers (fix: extract AAC and wrap in ADTS)
- (void)URLSession:(NSURLSession *)urlSession downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)fileUrl {
    NSURL *originalURL = downloadTask.originalRequest.URL;
#if !APOLLO_SIM_BUILD
    // Only the FFmpeg remux paths use these; the simulator build stubs them out.
    NSString *path = fileUrl.absoluteString;
    NSString *fixedPath = [path stringByAppendingString:@".fixed"];
#endif

    BOOL isCMAFAudio = [originalURL.absoluteString containsString:@"CMAF_AUDIO"] && [originalURL.pathExtension isEqualToString:@"mp4"];
    BOOL isHLSAudio = [originalURL.pathExtension isEqualToString:@"aac"];

    if (!isCMAFAudio && !isHLSAudio) {
        %orig;
        return;
    }

#if APOLLO_SIM_BUILD
    // Simulator/dev build: FFmpegKit is unavailable, so skip the audio container
    // remux and let Apollo download the stream unmodified. Affected v.redd.it
    // audio won't play correctly here — test that path on a device build.
    ApolloLog(@"[-URLSession:downloadTask:didFinishDownloadingToURL:] APOLLO_SIM_BUILD: skipping FFmpeg audio fix for %@", originalURL);
    %orig;
    return;
#else
    if (isCMAFAudio) {
        // CMAF audio is MP4 container with AAC - extract to ADTS format
        ApolloLog(@"[-URLSession:downloadTask:didFinishDownloadingToURL:] Converting CMAF MP4 audio to ADTS: %@", originalURL);
        NSString *ffmpegCommand = [NSString stringWithFormat:@"-y -loglevel info -i '%@' -vn -acodec copy -f adts '%@.fixed'", path, path];
        FFmpegSession *session = [FFmpegKit execute:ffmpegCommand];
        ReturnCode *returnCode = [session getReturnCode];
        if ([ReturnCode isSuccess:returnCode]) {
            // Replace original file with fixed version
            NSURL *fixedUrl = [NSURL URLWithString:fixedPath];
            NSFileManager *fileManager = [NSFileManager defaultManager];
            [fileManager removeItemAtURL:fileUrl error:nil];
            [fileManager moveItemAtURL:fixedUrl toURL:fileUrl error:nil];
        }
        %orig;
        return;
    }

    // MPEG-TS AAC processing
    ApolloLog(@"[-URLSession:downloadTask:didFinishDownloadingToURL:] Processing AAC file: %@", originalURL);

    MediaInformationSession *probeSession = [FFprobeKit getMediaInformation:path];
    ReturnCode *returnCode = [probeSession getReturnCode];
    if (![ReturnCode isSuccess:returnCode]) {
        %orig;
        return;
    }

    MediaInformation *mediaInformation = [probeSession getMediaInformation];
    if (!mediaInformation || ![mediaInformation.getFormat isEqualToString:@"mpegts"]) {
        %orig;
        return;
    }

    NSString *ffmpegCommand = [NSString stringWithFormat:@"-y -loglevel info -i '%@' -map 0 -dn -ignore_unknown -c copy -f adts '%@.fixed'", path, path];
    FFmpegSession *session = [FFmpegKit execute:ffmpegCommand];
    returnCode = [session getReturnCode];
    if ([ReturnCode isSuccess:returnCode]) {
        // Replace original file with fixed version
        NSURL *fixedUrl = [NSURL URLWithString:fixedPath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtURL:fileUrl error:nil];
        [fileManager moveItemAtURL:fixedUrl toURL:fileUrl error:nil];
    }
    %orig;
#endif
}

%end

// MARK: - Giphy Media Metadata Fix

static NSString *ApolloExtractGiphyIDFromToken(NSString *token) {
    if (![token isKindOfClass:[NSString class]] || token.length == 0) {
        return nil;
    }
    NSRange prefixRange = [token rangeOfString:@"giphy|"];
    if (prefixRange.location == NSNotFound) {
        return nil;
    }
    NSString *suffix = [token substringFromIndex:(prefixRange.location + prefixRange.length)];
    if (suffix.length == 0) {
        return nil;
    }
    NSRange nextPipe = [suffix rangeOfString:@"|"];
    NSString *giphyID = (nextPipe.location == NSNotFound) ? suffix : [suffix substringToIndex:nextPipe.location];
    return giphyID.length > 0 ? giphyID : nil;
}

static BOOL ApolloIsValidGiphyID(NSString *giphyID) {
    if (![giphyID isKindOfClass:[NSString class]] || giphyID.length == 0) {
        return NO;
    }
    // Giphy IDs are alphanumeric with possible underscores/dashes
    for (NSUInteger i = 0; i < giphyID.length; i++) {
        unichar c = [giphyID characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary *ApolloFixInvalidGiphyMetadata(NSDictionary *orig, NSUInteger *outSynthesizedCount) {
    if (outSynthesizedCount) {
        *outSynthesizedCount = 0;
    }
    if (![orig isKindOfClass:[NSDictionary class]] || orig.count == 0) {
        return orig;
    }

    NSMutableDictionary *fixed = nil;
    NSUInteger synthesizedCount = 0;

    for (NSString *key in orig) {
        if (![key isKindOfClass:[NSString class]] || ![key hasPrefix:@"giphy|"]) {
            continue;
        }

        NSDictionary *entry = orig[key];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *status = entry[@"status"];
        if ([status isKindOfClass:[NSString class]] && [status isEqualToString:@"valid"]) {
            continue;
        }

        NSString *giphyID = ApolloExtractGiphyIDFromToken(key);
        if (!ApolloIsValidGiphyID(giphyID)) {
            continue;
        }

        if (!fixed) {
            fixed = [orig mutableCopy];
        }

        NSString *extURL = [NSString stringWithFormat:@"https://giphy.com/gifs/%@", giphyID];
        NSString *gifURL = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif", giphyID];
        NSString *thumbURL = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/200w_s.gif", giphyID];

        fixed[key] = @{
            @"status": @"valid",
            @"e": @"AnimatedImage",
            @"m": @"image/gif",
            @"ext": extURL,
            @"p": @[@{@"y": @200, @"x": @200, @"u": thumbURL}],
            // Must use gifURL for 'mp4' or else will open in webview
            @"s": @{@"y": @200, @"gif": gifURL, @"mp4": gifURL, @"x": @200},
            @"t": @"giphy",
            @"id": key,
        };
        synthesizedCount++;
    }

    if (outSynthesizedCount) {
        *outSynthesizedCount = synthesizedCount;
    }
    return fixed ?: orig;
}

static NSDictionary *ApolloFixMediaMetadata(NSDictionary *orig, NSUInteger *outGiphyCount, NSUInteger *outRedditGifCount) {
    if (outGiphyCount) *outGiphyCount = 0;
    if (outRedditGifCount) *outRedditGifCount = 0;
    if (![orig isKindOfClass:[NSDictionary class]] || orig.count == 0) return orig;

    NSUInteger giphyCount = 0;
    NSDictionary *fixed = ApolloFixInvalidGiphyMetadata(orig, &giphyCount);
    NSUInteger redditGifCount = 0;
    fixed = ApolloFixRedditHostedGifMetadata(fixed, &redditGifCount);

    if (outGiphyCount) *outGiphyCount = giphyCount;
    if (outRedditGifCount) *outRedditGifCount = redditGifCount;
    return fixed;
}

// MARK: - "Processing img" Placeholder Fix (shared between RDKComment and RDKLink)

// Resolve a single media ID to an image URL from media_metadata.
// Returns nil if the ID is not found or invalid.
static NSString *ApolloResolveMediaURL(NSString *mediaId, NSDictionary *metadata, NSString **outLabel) {
    if (outLabel) *outLabel = @"Image";

    NSDictionary *entry = metadata[mediaId];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return nil;

    BOOL preferMP4 = (sPreferredGIFFallbackFormat != 0);
    NSString *url = ApolloMediaDisplayURLFromMetadataEntry(mediaId, entry, preferMP4);
    if (url.length == 0) return nil;

    if (outLabel && [[entry objectForKey:@"e"] isEqualToString:@"AnimatedImage"]) *outLabel = @"GIF";
    return url;
}

// Replace "*Processing img <id>...*" placeholders with markdown image links.
// Uses media_metadata for URL resolution, with an optional i.redd.it fallback extension
// for when metadata is unavailable (e.g. posts where media_metadata hasn't been populated yet).
static NSString *ApolloFixProcessingImgPlaceholders(NSString *text, NSDictionary *metadata, NSString *fallbackExtension) {
    if (!text || ![text containsString:@"Processing img "]) return text;

    BOOL hasMetadata = [metadata isKindOfClass:[NSDictionary class]] && metadata.count > 0;
    if (!hasMetadata && !fallbackExtension) return text;

    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\\*Processing img ([a-zA-Z0-9_]+)\\.{3}\\*" options:0 error:nil];
    });

    NSMutableString *fixed = [text mutableCopy];
    NSArray *matches = [regex matchesInString:fixed options:0 range:NSMakeRange(0, fixed.length)];
    if (matches.count == 0) return text;

    NSUInteger replacedCount = 0;
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *mediaId = [fixed substringWithRange:[match rangeAtIndex:1]];

        NSString *label = nil;
        NSString *url = hasMetadata ? ApolloResolveMediaURL(mediaId, metadata, &label) : nil;

        // Fallback: construct i.redd.it URL
        if (!url && fallbackExtension) {
            url = [NSString stringWithFormat:@"https://i.redd.it/%@.%@", mediaId, fallbackExtension];
            label = @"Image";
        }

        if (!url) continue;

        NSString *replacement = [NSString stringWithFormat:@"[%@](%@)", label, url];
        [fixed replaceCharactersInRange:match.range withString:replacement];
        replacedCount++;
    }

    if (replacedCount > 0) {
        ApolloLog(@"[ProcessingImg] Replaced %lu placeholder%@ in text",
            (unsigned long)replacedCount, (replacedCount == 1 ? @"" : @"s"));
    }

    return replacedCount > 0 ? fixed : text;
}

// Rewrite Reddit-native Giphy markdown tokens `![gif](giphy|<id>)` (which our
// markdown toolbar inserts and Reddit's server recognizes natively) into real
// Giphy CDN URLs so Apollo's inline-image renderer can display the GIF in the
// optimistic local view right after submit — before Reddit's canonical
// response (with proper `mediaMetadata` entries keyed by `giphy|<id>`) comes
// back. Without this, Apollo tries to load `giphy|<id>` as a URL, fails, and
// shows its built-in "If you are looking for an image, it was probably
// deleted." placeholder.
//
// CRITICAL: only rewrite per-token when there is NO matching `mediaMetadata`
// entry for that giphy ID. Once Reddit returns canonical metadata, Apollo's
// own renderer uses the `giphy|<id>` token to look up the metadata entry and
// render the GIF inline — rewriting the token would break that path and
// produce "[Unknown Image]". The optimistic local case (no metadata yet) is
// the only one where we want the rewrite.
static NSString *ApolloRewriteNativeGiphyTokens(NSString *text, NSDictionary *metadata) {
    if (text.length == 0) return text;
    if ([text rangeOfString:@"(giphy|"].location == NSNotFound) return text;

    NSRegularExpression *regex = ApolloNativeGiphyMarkdownTokenRegex();
    if (!regex) return text;

    NSArray *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    BOOL hasMetadata = [metadata isKindOfClass:[NSDictionary class]] && metadata.count > 0;
    NSMutableString *fixed = [text mutableCopy];
    NSUInteger replacedCount = 0;
    NSUInteger skippedHasMetadataCount = 0;
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *giphyID = [fixed substringWithRange:[match rangeAtIndex:1]];
        if (giphyID.length == 0) continue;

        // Skip if Apollo's native renderer can handle this token via mediaMetadata.
        if (hasMetadata) {
            NSString *metadataKey = [NSString stringWithFormat:@"giphy|%@", giphyID];
            id entry = metadata[metadataKey];
            if ([entry isKindOfClass:[NSDictionary class]]) {
                skippedHasMetadataCount++;
                continue;
            }
        }

        NSString *replacement = [NSString stringWithFormat:@"![GIF](https://media.giphy.com/media/%@/giphy.gif)", giphyID];
        [fixed replaceCharactersInRange:match.range withString:replacement];
        replacedCount++;
    }

    if (replacedCount > 0 || skippedHasMetadataCount > 0) {
        ApolloLog(@"[NativeGiphyBody] rewrote=%lu skipped(hasMetadata)=%lu",
            (unsigned long)replacedCount, (unsigned long)skippedHasMetadataCount);
    }
    return replacedCount > 0 ? fixed : text;
}

%hook RDKComment

- (void)setMediaMetadata:(NSDictionary *)mediaMetadata {
    NSUInteger giphyCount = 0, redditGifCount = 0;
    NSDictionary *fixed = ApolloFixMediaMetadata(mediaMetadata, &giphyCount, &redditGifCount);
    %orig(fixed);
}

- (NSString *)body {
    NSDictionary *metadata = self.mediaMetadata;
    NSString *fixed = ApolloFixProcessingImgPlaceholders(%orig, metadata, nil);
    return ApolloRewriteNativeGiphyTokens(fixed, metadata);
}

%end

%hook RDKLink

- (void)setMediaMetadata:(NSDictionary *)mediaMetadata {
    NSUInteger giphyCount = 0, redditGifCount = 0;
    NSDictionary *fixed = ApolloFixMediaMetadata(mediaMetadata, &giphyCount, &redditGifCount);
    %orig(fixed);
}

- (NSString *)selfText {
    // Determine fallback extension from preview source image URL
    NSString *fallbackExt = nil;
    NSDictionary *metadata = self.mediaMetadata;
    if (![metadata isKindOfClass:[NSDictionary class]] || metadata.count == 0) {
        RDKLinkPreviewItem *sourceImage = self.previewMedia.sourceImage;
        if (sourceImage.URL) {
            fallbackExt = sourceImage.URL.path.pathExtension;
        }
        if (fallbackExt.length == 0) fallbackExt = @"png";
    }

    NSString *fixed = ApolloFixProcessingImgPlaceholders(%orig, metadata, fallbackExt);
    return ApolloRewriteNativeGiphyTokens(fixed, metadata);
}

%end

%ctor {
    %init;
}
