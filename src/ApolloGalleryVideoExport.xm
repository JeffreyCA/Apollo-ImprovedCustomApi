// ApolloGalleryVideoExport.xm — see ApolloGalleryVideoExport.h.
//
// Compiled as ObjC++ (.xm); there are no Logos hooks in here.

#import "ApolloGalleryVideoExport.h"
#import "ApolloCommon.h"

#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

static NSTimeInterval const kApolloGalleryExportManifestTimeout = 10.0;
static NSUInteger const kApolloGalleryExportManifestMaximumBytes = 1024 * 1024;

#pragma mark - DASH manifest

// The v.redd.it asset id — the first path component of the URL.
static NSString *ApolloGalleryExportRedditAssetID(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (![url.host.lowercaseString isEqualToString:@"v.redd.it"]) return nil;
    for (NSString *component in url.pathComponents) {
        if (component.length > 0 && ![component isEqualToString:@"/"]) return component;
    }
    return nil;
}

// XML scopes preserve the MIME/content type and BaseURL inherited from an
// AdaptationSet. Treating every non-audio Representation as video can select
// subtitles, or silently lose audio whose type was declared on its parent.
// SegmentTemplate/List resources are not standalone files and cannot be passed
// to the download-and-mux path. Unknown kinds are deliberately not video.
@interface ApolloGalleryExportManifestParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *scopes;
@property (nonatomic, strong) NSURL *manifestURL;
@property (nonatomic, strong) NSURL *videoURL;
@property (nonatomic, strong) NSURL *audioURL;
@property (nonatomic) long long videoBandwidth;
@property (nonatomic) long long audioBandwidth;
@property (nonatomic) BOOL audioDeclared;
@property (nonatomic) BOOL sawMPD;
@end

static NSString *ApolloGalleryExportManifestKind(NSDictionary<NSString *, NSString *> *attributes) {
    NSString *contentType = attributes[@"contentType"].lowercaseString;
    NSString *mimeType = attributes[@"mimeType"].lowercaseString;
    if ([contentType isEqualToString:@"audio"] || [mimeType hasPrefix:@"audio/"]) return @"audio";
    if ([contentType isEqualToString:@"video"] || [mimeType hasPrefix:@"video/"]) return @"video";
    // Explicitly non-A/V content must not inherit an A/V parent's kind.
    if (contentType.length || mimeType.length) return @"other";
    return nil;
}

@implementation ApolloGalleryExportManifestParser
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
 namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    NSString *name = [[elementName componentsSeparatedByString:@":"] lastObject];
    NSMutableDictionary *parent = self.scopes.lastObject;
    NSMutableDictionary *scope = [NSMutableDictionary dictionary];
    scope[@"name"] = name;
    scope[@"base"] = parent[@"base"] ?: self.manifestURL;
    scope[@"hasBase"] = parent[@"hasBase"] ?: @NO;
    scope[@"segmented"] = parent[@"segmented"] ?: @NO;
    scope[@"kind"] = ApolloGalleryExportManifestKind(attributes) ?: parent[@"kind"] ?: @"other";
    scope[@"bandwidth"] = @([attributes[@"bandwidth"] longLongValue]);
    if (self.scopes.count == 0) self.sawMPD = [name isEqualToString:@"MPD"];
    if (([name isEqualToString:@"AdaptationSet"] || [name isEqualToString:@"Representation"]) &&
        [scope[@"kind"] isEqualToString:@"audio"]) self.audioDeclared = YES;
    if ([name isEqualToString:@"BaseURL"]) scope[@"text"] = [NSMutableString string];
    if ([name isEqualToString:@"SegmentTemplate"] || [name isEqualToString:@"SegmentList"]) {
        parent[@"segmented"] = @YES;
    }
    [self.scopes addObject:scope];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.scopes.lastObject[@"text"] appendString:string];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    NSString *text = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (text) [self.scopes.lastObject[@"text"] appendString:text];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName
 namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    NSMutableDictionary *scope = self.scopes.lastObject;
    NSString *name = scope[@"name"];
    if ([name isEqualToString:@"Representation"] && [scope[@"hasBase"] boolValue] &&
        ![scope[@"segmented"] boolValue]) {
        NSURL *URL = scope[@"base"];
        NSString *scheme = URL.scheme.lowercaseString;
        NSString *extension = URL.pathExtension.lowercaseString;
        BOOL usable = ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) &&
            ![extension isEqualToString:@"mpd"] && ![extension isEqualToString:@"m3u8"] &&
            URL.lastPathComponent.length > 0 && ![URL.path hasSuffix:@"/"];
        long long bandwidth = [scope[@"bandwidth"] longLongValue];
        if (usable && [scope[@"kind"] isEqualToString:@"audio"] && bandwidth > self.audioBandwidth) {
            self.audioBandwidth = bandwidth;
            self.audioURL = URL;
        } else if (usable && [scope[@"kind"] isEqualToString:@"video"] && bandwidth > self.videoBandwidth) {
            self.videoBandwidth = bandwidth;
            self.videoURL = URL;
        }
    }
    [self.scopes removeLastObject];
    if ([name isEqualToString:@"BaseURL"]) {
        NSMutableDictionary *parent = self.scopes.lastObject;
        NSString *relative = [scope[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *resolved = relative.length ? [NSURL URLWithString:relative relativeToURL:parent[@"base"]].absoluteURL : nil;
        // DASH may list alternatives. The first BaseURL is a choice, not a
        // component to append to the previous alternative.
        if (resolved && ![parent[@"ownBase"] boolValue]) {
            parent[@"base"] = resolved;
            parent[@"hasBase"] = @YES;
            parent[@"ownBase"] = @YES;
        }
    }
}
@end

// Highest bandwidth wins within each known A/V kind. audioDeclared remains
// true even if that adaptation has no usable URL: a strict batch save must not
// turn a missing/unsupported audio representation into a silent success.
static BOOL ApolloGalleryExportParseManifest(NSData *mpdData, NSURL *mpdURL,
                                              NSURL *__strong *outVideo, NSURL *__strong *outAudio,
                                              BOOL *outAudioDeclared) {
    if (outVideo) *outVideo = nil;
    if (outAudio) *outAudio = nil;
    if (outAudioDeclared) *outAudioDeclared = NO;
    if (mpdData.length == 0) return NO;
    ApolloGalleryExportManifestParser *delegate = [[ApolloGalleryExportManifestParser alloc] init];
    delegate.scopes = [NSMutableArray array];
    delegate.manifestURL = mpdURL;
    delegate.videoBandwidth = -1;
    delegate.audioBandwidth = -1;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:mpdData];
    parser.shouldResolveExternalEntities = NO;
    parser.delegate = delegate;
    if (![parser parse] || !delegate.sawMPD) return NO;
    if (outVideo) *outVideo = delegate.videoURL;
    if (outAudio) *outAudio = delegate.audioURL;
    if (outAudioDeclared) *outAudioDeclared = delegate.audioDeclared;
    return YES;
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
    // A manifest is an instruction document, never a progressive fallback.
    // This matters when the native RedditVideo model supplies only dashUrl.
    NSString *sourceExtension = url.pathExtension.lowercaseString;
    if ([sourceExtension isEqualToString:@"mpd"] || [sourceExtension isEqualToString:@"m3u8"]) {
        completion(nil);
        return;
    }
    static NSURLSession *downloadSession;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache = nil;
        configuration.timeoutIntervalForRequest = 60.0;
        configuration.timeoutIntervalForResource = 300.0;
        downloadSession = [NSURLSession sessionWithConfiguration:configuration];
    });
    NSURLSessionDownloadTask *task =
        [downloadSession downloadTaskWithURL:url
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
        NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                    isDirectory:NO];
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
static void ApolloGalleryExportMux(NSURL *videoFile, NSURL *audioFile, BOOL strict,
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
        // Preserve the old single-save fallback, but never let a batch report
        // complete success after silently dropping a declared audio track.
        ApolloLog(@"[GalleryExport] mux: no audio track strict=%d", strict);
        completion(strict ? nil : videoFile);
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
        // Only the legacy single-save path permits an audio-less fallback.
        ApolloLog(@"[GalleryExport] mux: audio insert failed: %@", error.localizedDescription);
        if (strict) {
            completion(nil);
            return;
        }
    }

    NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp4"];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                  isDirectory:NO];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:NULL];

    // `export` is a reserved word in C++, and this file is ObjC++.
    AVAssetExportSession *session =
        [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    if (!session) {
        completion(strict ? nil : videoFile);
        return;
    }
    session.outputURL = outputURL;
    session.outputFileType = AVFileTypeMPEG4;
    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status != AVAssetExportSessionStatusCompleted) {
            ApolloLog(@"[GalleryExport] mux export %ld: %@",
                      (long)session.status, session.error.localizedDescription ?: @"");
            ApolloGalleryExportRemove(outputURL);
            // Preserve the legacy fallback; a strict batch counts a failure.
            completion(strict ? nil : videoFile);
            return;
        }
        if (strict) {
            AVURLAsset *result = [AVURLAsset URLAssetWithURL:outputURL options:nil];
            if ([result tracksWithMediaType:AVMediaTypeVideo].count == 0 ||
                [result tracksWithMediaType:AVMediaTypeAudio].count == 0) {
                ApolloGalleryExportRemove(outputURL);
                completion(nil);
                return;
            }
        }
        completion(outputURL);
    }];
    // Batch cancellation waits for the current video to finish. Bound a stuck
    // passthrough export too, so it cannot keep that batch locked indefinitely.
    __weak AVAssetExportSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AVAssetExportSession *runningSession = weakSession;
        if (runningSession.status == AVAssetExportSessionStatusWaiting ||
            runningSession.status == AVAssetExportSessionStatusExporting) [runningSession cancelExport];
    });
}

#pragma mark - Entry point

static void ApolloGallerySaveVideoToPhotosImpl(NSURL *progressiveURL, BOOL strict,
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
    NSURLSessionDataTask *manifestTask = ApolloStartBoundedDataRequest(request, kApolloGalleryExportManifestMaximumBytes, nil,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSInteger httpStatus = response.statusCode;
        NSURL *videoURL = nil, *audioURL = nil;
        BOOL audioDeclared = NO;
        BOOL parsed = NO;
        if (!error && httpStatus >= 200 && httpStatus < 300 && data.length > 0) {
            parsed = ApolloGalleryExportParseManifest(data, manifestURL, &videoURL, &audioURL, &audioDeclared);
        }
        if (strict && (!parsed || !videoURL || (audioDeclared && !audioURL))) {
            ApolloLog(@"[GalleryExport] strict manifest rejected HTTP=%ld parsed=%d video=%d audioDeclared=%d audio=%d",
                      (long)httpStatus, parsed, videoURL != nil, audioDeclared, audioURL != nil);
            ApolloGalleryExportMain(^{ completion(NO, @"Couldn't load the complete video"); });
            return;
        }
        // Only a legacy single-item save may use a progressive fallback after
        // an unreadable manifest; strict exports returned a failure above.
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
                    if (strict) {
                        ApolloGalleryExportRemove(videoFile);
                        ApolloGalleryExportMain(^{ completion(NO, @"Couldn't download video audio"); });
                        return;
                    }
                    // No audio to merge; save what we have.
                    ApolloGalleryExportWriteToPhotos(videoFile, @[], completion);
                    return;
                }
                ApolloGalleryExportMux(videoFile, audioFile, strict, ^(NSURL *muxedFile) {
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
    });
    // Request timeout is an idle timeout; a trickling server must not hold a
    // cancelled batch open indefinitely while staying below the byte limit.
    __weak NSURLSessionDataTask *weakManifestTask = manifestTask;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSURLSessionDataTask *runningTask = weakManifestTask;
        if (runningTask.state == NSURLSessionTaskStateRunning ||
            runningTask.state == NSURLSessionTaskStateSuspended) [runningTask cancel];
    });
}

void ApolloGallerySaveVideoToPhotos(NSURL *progressiveURL,
                                    void (^status)(NSString *text),
                                    void (^completion)(BOOL success, NSString *message)) {
    ApolloGallerySaveVideoToPhotosImpl(progressiveURL, NO, status, completion);
}

void ApolloGallerySaveVideoToPhotosStrict(NSURL *sourceURL,
                                          void (^status)(NSString *text),
                                          void (^completion)(BOOL success, NSString *message)) {
    ApolloGallerySaveVideoToPhotosImpl(sourceURL, YES, status, completion);
}
