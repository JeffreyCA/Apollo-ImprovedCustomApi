// ApolloGalleryVideoExport.xm — see ApolloGalleryVideoExport.h.
//
// Compiled as ObjC++ (.xm) purely so it links directly against the DASH helpers
// in ApolloShareAsVideo.xm; there are no Logos hooks in here.

#import "ApolloGalleryVideoExport.h"
#import "ApolloCommon.h"

#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

static NSTimeInterval const kApolloGalleryExportManifestTimeout = 10.0;

#pragma mark - DASH manifest

// The v.redd.it asset id — the first path component of the URL.
static NSString *ApolloGalleryExportRedditAssetID(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if ([url.host.lowercaseString rangeOfString:@"v.redd.it"].location == NSNotFound) return nil;
    for (NSString *component in url.pathComponents) {
        if (component.length > 0 && ![component isEqualToString:@"/"]) return component;
    }
    return nil;
}

// Picks the HIGHEST-bitrate video and audio representations out of a Reddit DASH
// manifest.
//
// Deliberately not shared with Share as Video's parser, for two reasons. That
// one wants the LOWEST bitrate (it's building a share card, where small wins);
// a save wants the best copy available. And it keys off `contentType="video"`
// with a `<BaseURL>*.mp4</BaseURL>` pattern, which only matches Reddit's newer
// manifests — older ones carry no contentType at all, put mimeType on the
// Representation, and use extension-less BaseURLs ("DASH_720", "audio"). Those
// extension-less paths are the ONLY ones that serve: the .mp4 spellings 403.
//
// Returns absolute URLs; either may be nil.
static void ApolloGalleryExportParseManifest(NSData *mpdData, NSURL *mpdURL,
                                             NSURL *__strong *outVideo, NSURL *__strong *outAudio) {
    if (outVideo) *outVideo = nil;
    if (outAudio) *outAudio = nil;
    NSString *xml = mpdData.length > 0 ? [[NSString alloc] initWithData:mpdData encoding:NSUTF8StringEncoding] : nil;
    if (xml.length == 0) return;

    // Each <Representation …> carries its own mimeType/bandwidth, and its
    // <BaseURL> is the next one in document order.
    // NOTE the doubled backslash: in an ObjC string literal "\b" is a BACKSPACE
    // character, so a single one would compile into a pattern that matches
    // nothing at all (and every track would silently fall back).
    NSRegularExpression *representations =
        [NSRegularExpression regularExpressionWithPattern:@"<Representation\\b([^>]*)>(.*?)</Representation>"
                                                  options:NSRegularExpressionDotMatchesLineSeparators
                                                    error:nil];
    NSRegularExpression *baseURL =
        [NSRegularExpression regularExpressionWithPattern:@"<BaseURL>([^<]+)</BaseURL>" options:0 error:nil];
    if (!representations || !baseURL) return;

    long long bestVideoBandwidth = -1, bestAudioBandwidth = -1;

    for (NSTextCheckingResult *match in [representations matchesInString:xml options:0
                                                                   range:NSMakeRange(0, xml.length)]) {
        NSString *attributes = [xml substringWithRange:[match rangeAtIndex:1]];
        NSString *body = [xml substringWithRange:[match rangeAtIndex:2]];

        NSTextCheckingResult *base = [baseURL firstMatchInString:body options:0
                                                           range:NSMakeRange(0, body.length)];
        if (!base || base.numberOfRanges < 2) continue;
        NSString *relative = [[body substringWithRange:[base rangeAtIndex:1]]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (relative.length == 0) continue;
        NSURL *resolved = [NSURL URLWithString:relative relativeToURL:mpdURL].absoluteURL;
        if (!resolved) continue;

        BOOL isAudio = [attributes rangeOfString:@"audio/" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [attributes rangeOfString:@"contentType=\"audio\"" options:NSCaseInsensitiveSearch].location != NSNotFound;

        long long bandwidth = 0;
        NSRange bandwidthRange = [attributes rangeOfString:@"bandwidth=\""];
        if (bandwidthRange.location != NSNotFound) {
            NSString *tail = [attributes substringFromIndex:NSMaxRange(bandwidthRange)];
            bandwidth = [tail longLongValue];
        }

        if (isAudio) {
            if (bandwidth > bestAudioBandwidth) { bestAudioBandwidth = bandwidth; if (outAudio) *outAudio = resolved; }
        } else {
            if (bandwidth > bestVideoBandwidth) { bestVideoBandwidth = bandwidth; if (outVideo) *outVideo = resolved; }
        }
    }
}

#pragma mark - Small helpers

static void ApolloGalleryExportMain(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

// Downloads `url` to a temp file with `extension`, because AVFoundation is far
// happier composing from local files than from remote assets, and Photos needs
// a real file with a real extension either way.
static void ApolloGalleryExportDownload(NSURL *url, NSString *extension,
                                        void (^completion)(NSURL *_Nullable fileURL)) {
    NSURLSessionDownloadTask *task =
        [[NSURLSession sharedSession] downloadTaskWithURL:url
                                        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!location || error || (status > 0 && (status < 200 || status >= 300))) {
            ApolloLog(@"[GalleryExport] download failed (%ld) %@: %@",
                      (long)status, url.lastPathComponent, error.localizedDescription ?: @"");
            completion(nil);
            return;
        }
        NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:extension];
        NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:NULL];
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&moveError]) {
            ApolloLog(@"[GalleryExport] move failed: %@", moveError.localizedDescription);
            completion(nil);
            return;
        }
        completion(fileURL);
    }];
    [task resume];
}

static void ApolloGalleryExportRemove(NSURL *_Nullable fileURL) {
    if (fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:NULL];
}

#pragma mark - Photos

static void ApolloGalleryExportWriteToPhotos(NSURL *fileURL, NSArray<NSURL *> *scratch,
                                             void (^completion)(BOOL success, NSString *message)) {
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        for (NSURL *url in scratch) ApolloGalleryExportRemove(url);
        ApolloGalleryExportRemove(fileURL);
        ApolloGalleryExportMain(^{ completion(ok, message); });
    };

    void (^performSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypeVideo fileURL:fileURL options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            ApolloLog(@"[GalleryExport] Photos write %@%@", success ? @"OK" : @"FAILED",
                      success ? @"" : [@": " stringByAppendingString:error.localizedDescription ?: @"?"]);
            finish(success, success ? @"Saved" : @"Save failed");
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) performSave();
            else finish(NO, @"Photos access denied");
        }];
    } else if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        performSave();
    } else {
        finish(NO, @"Photos access denied");
    }
}

#pragma mark - Muxing

// Splices a video-only file and an audio-only file into a single mp4.
// Passthrough preset: both tracks are already H.264/AAC, so this is a remux —
// no re-encode, no quality loss, and fast enough to feel like a plain save.
static void ApolloGalleryExportMux(NSURL *videoFile, NSURL *audioFile,
                                   void (^completion)(NSURL *_Nullable muxedFile)) {
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoFile
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioFile
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];

    AVAssetTrack *sourceVideo = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *sourceAudio = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!sourceVideo) {
        ApolloLog(@"[GalleryExport] mux: no video track");
        completion(nil);
        return;
    }
    if (!sourceAudio) {
        // Audio side unusable — the caller still has a perfectly good silent
        // video file, so hand that back rather than failing the whole save.
        ApolloLog(@"[GalleryExport] mux: no audio track; keeping video only");
        completion(videoFile);
        return;
    }

    // Trim to the shorter track: Reddit's two representations can differ by a
    // frame or two, and an over-long audio track would tail off into silence.
    CMTime duration = CMTimeMinimum(videoAsset.duration, audioAsset.duration);
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeGetSeconds(duration) <= 0.0) {
        duration = videoAsset.duration;
    }
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, duration);

    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *videoTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *error = nil;
    if (![videoTrack insertTimeRange:range ofTrack:sourceVideo atTime:kCMTimeZero error:&error]) {
        ApolloLog(@"[GalleryExport] mux: video insert failed: %@", error.localizedDescription);
        completion(nil);
        return;
    }
    videoTrack.preferredTransform = sourceVideo.preferredTransform;

    AVMutableCompositionTrack *audioTrack =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    if (![audioTrack insertTimeRange:range ofTrack:sourceAudio atTime:kCMTimeZero error:&error]) {
        // Losing the audio is better than losing the save.
        ApolloLog(@"[GalleryExport] mux: audio insert failed: %@", error.localizedDescription);
    }

    NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp4"];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:NULL];

    // `export` is a reserved word in C++, and this file is ObjC++.
    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeMPEG4;
    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status != AVAssetExportSessionStatusCompleted) {
            ApolloLog(@"[GalleryExport] mux export %ld: %@",
                      (long)session.status, session.error.localizedDescription ?: @"");
            ApolloGalleryExportRemove(outputURL);
            // Fall back to the silent video rather than dropping the save.
            completion(videoFile);
            return;
        }
        completion(outputURL);
    }];
}

#pragma mark - Entry point

void ApolloGallerySaveVideoToPhotos(NSURL *progressiveURL,
                                    void (^status)(NSString *text),
                                    void (^completion)(BOOL success, NSString *message)) {
    if (!progressiveURL) {
        ApolloGalleryExportMain(^{ completion(NO, @"Nothing to save"); });
        return;
    }
    void (^report)(NSString *) = ^(NSString *text) {
        if (status) ApolloGalleryExportMain(^{ status(text); });
    };
    report(@"Saving…");

    NSString *assetID = ApolloGalleryExportRedditAssetID(progressiveURL);
    if (assetID.length == 0) {
        // Self-contained file (imgur mp4, Reddit's silent GIF transcode): the
        // download IS the finished article.
        ApolloGalleryExportDownload(progressiveURL, @"mp4", ^(NSURL *fileURL) {
            if (!fileURL) {
                ApolloGalleryExportMain(^{ completion(NO, @"Save failed"); });
                return;
            }
            ApolloGalleryExportWriteToPhotos(fileURL, @[], completion);
        });
        return;
    }

    // v.redd.it: resolve the manifest so the audio representation can be muxed
    // back in, otherwise the save is silent.
    NSURL *manifestURL = [NSURL URLWithString:
        [NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd", assetID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:manifestURL
                                                          cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                      timeoutInterval:kApolloGalleryExportManifestTimeout];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger httpStatus = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSURL *videoURL = nil, *audioURL = nil;
        if (!error && httpStatus >= 200 && httpStatus < 300 && data.length > 0) {
            ApolloGalleryExportParseManifest(data, manifestURL, &videoURL, &audioURL);
        }
        // Manifest unreadable: the progressive fallback still gives a (silent)
        // video, which beats refusing to save at all.
        if (!videoURL) videoURL = progressiveURL;
        ApolloLog(@"[GalleryExport] v.redd.it %@ manifest=%ld video=%@ audio=%@",
                  assetID, (long)httpStatus,
                  videoURL.lastPathComponent ?: @"none", audioURL.lastPathComponent ?: @"none");

        ApolloGalleryExportDownload(videoURL, @"mp4", ^(NSURL *videoFile) {
            if (!videoFile) {
                ApolloGalleryExportMain(^{ completion(NO, @"Save failed"); });
                return;
            }
            if (!audioURL) {
                ApolloGalleryExportWriteToPhotos(videoFile, @[], completion);
                return;
            }
            report(@"Merging audio…");
            ApolloGalleryExportDownload(audioURL, @"mp4", ^(NSURL *audioFile) {
                if (!audioFile) {
                    // No audio to merge; save what we have.
                    ApolloGalleryExportWriteToPhotos(videoFile, @[], completion);
                    return;
                }
                ApolloGalleryExportMux(videoFile, audioFile, ^(NSURL *muxedFile) {
                    if (!muxedFile) {
                        ApolloGalleryExportRemove(videoFile);
                        ApolloGalleryExportRemove(audioFile);
                        ApolloGalleryExportMain(^{ completion(NO, @"Save failed"); });
                        return;
                    }
                    // The mux can hand back the video file itself as a fallback;
                    // don't list it as scratch in that case or it'd be deleted
                    // before Photos reads it.
                    NSMutableArray<NSURL *> *scratch = [NSMutableArray arrayWithObject:audioFile];
                    if (![muxedFile isEqual:videoFile]) [scratch addObject:videoFile];
                    ApolloGalleryExportWriteToPhotos(muxedFile, scratch, completion);
                });
            });
        });
    }] resume];
}
