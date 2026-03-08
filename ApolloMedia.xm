#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

#import "ffmpeg-kit/ffmpeg-kit/include/MediaInformationSession.h"
#import "ffmpeg-kit/ffmpeg-kit/include/MediaInformation.h"
#import "ffmpeg-kit/ffmpeg-kit/include/FFmpegKit.h"
#import "ffmpeg-kit/ffmpeg-kit/include/FFprobeKit.h"

// Regex patterns for v.redd.it CMAF audio streams (Reddit switched from MPEG-TS to CMAF around November 2025)
static NSString *const HLSAudioRegexPattern = @"#EXT-X-MEDIA:.*?\"(HLS_AUDIO.*?)\\.m3u8";
static NSString *const CMAFAudioRegexPattern = @"#EXT-X-MEDIA:.*?\"((?:HLS|CMAF)_AUDIO.*?)\\.m3u8";
static NSString *const CMAFAudioIdentifier = @"CMAF_AUDIO";

// Regex patterns for Streamable URLs (some Streamable links have new query strings)
static NSString *const StreamableRegexPattern = @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)$";
static NSString *const StreamableRegexPatternWithQueryString = @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)(?:\\?.*)?$";

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

- (void)displayDidRefresh:(CADisplayLink *)displayLink {
    // Get required ivars
    FLAnimatedImage *animatedImage = MSHookIvar<FLAnimatedImage *>(self, "_animatedImage");
    if (!animatedImage) {
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
    NSString *path = fileUrl.absoluteString;
    NSString *fixedPath = [path stringByAppendingString:@".fixed"];

    BOOL isCMAFAudio = [originalURL.absoluteString containsString:@"CMAF_AUDIO"] && [originalURL.pathExtension isEqualToString:@"mp4"];
    BOOL isHLSAudio = [originalURL.pathExtension isEqualToString:@"aac"];

    if (!isCMAFAudio && !isHLSAudio) {
        %orig;
        return;
    }

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

// MARK: - "Processing img" Placeholder Fix (shared between RDKComment and RDKLink)

// Resolve a single media ID to an image URL from media_metadata.
// Returns nil if the ID is not found or invalid.
static NSString *ApolloResolveMediaURL(NSString *mediaId, NSDictionary *metadata, NSString **outLabel) {
    if (outLabel) *outLabel = @"Image";

    NSDictionary *entry = metadata[mediaId];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    if (![[entry objectForKey:@"status"] isEqualToString:@"valid"]) return nil;

    NSString *url = nil;
    NSDictionary *source = entry[@"s"];
    if ([source isKindOfClass:[NSDictionary class]]) {
        url = (sPreferredGIFFallbackFormat == 0)
            ? (source[@"gif"] ?: source[@"mp4"] ?: source[@"u"])
            : (source[@"mp4"] ?: source[@"gif"] ?: source[@"u"]);
    }
    if (!url) {
        NSArray *previews = entry[@"p"];
        if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
            url = [previews.lastObject objectForKey:@"u"];
        }
    }
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return nil;

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

%hook RDKComment

- (void)setMediaMetadata:(NSDictionary *)mediaMetadata {
    NSUInteger synthesizedCount = 0;
    NSDictionary *fixed = ApolloFixInvalidGiphyMetadata(mediaMetadata, &synthesizedCount);
    %orig(fixed);
}

- (NSString *)body {
    return ApolloFixProcessingImgPlaceholders(%orig, self.mediaMetadata, nil);
}

%end

%hook RDKLink

- (void)setMediaMetadata:(NSDictionary *)mediaMetadata {
    NSUInteger synthesizedCount = 0;
    NSDictionary *fixed = ApolloFixInvalidGiphyMetadata(mediaMetadata, &synthesizedCount);
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

    return ApolloFixProcessingImgPlaceholders(%orig, metadata, fallbackExt);
}

%end

%ctor {
    %init;
}
