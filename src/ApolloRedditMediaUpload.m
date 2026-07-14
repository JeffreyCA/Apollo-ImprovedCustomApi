#import "ApolloRedditMediaUpload.h"
#import "ApolloCommon.h"
#import "ApolloWebJSON.h"

#import <objc/runtime.h>

static NSString *const ApolloRedditUploadErrorDomain = @"ApolloRedditMediaUpload";
static char kApolloRedditMediaUploadProgressOperationKey;

static NSError *ApolloRedditUploadError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ApolloRedditUploadErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Reddit media upload failed"}];
}

static NSError *ApolloRedditUploadCancelledError(void) {
    return [NSError errorWithDomain:NSURLErrorDomain
                               code:NSURLErrorCancelled
                           userInfo:@{NSLocalizedDescriptionKey: @"Reddit media upload was cancelled"}];
}

@interface ApolloRedditMediaUploadOperation ()

@property (nonatomic, copy, readwrite) NSString *identifier;
@property (atomic, assign, readwrite, getter=isCancelled) BOOL cancelled;
@property (nonatomic, strong) NSURLSessionTask *assetTask;
@property (nonatomic, strong) NSURLSessionTask *storageTask;

- (BOOL)apolloSetAssetTask:(NSURLSessionTask *)task;
- (BOOL)apolloSetStorageTask:(NSURLSessionTask *)task;
- (void)apolloClearStorageTask:(NSURLSessionTask *)task;

@end

@implementation ApolloRedditMediaUploadOperation

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [NSUUID UUID].UUIDString;
    }
    return self;
}

- (void)cancel {
    NSURLSessionTask *assetTask = nil;
    NSURLSessionTask *storageTask = nil;
    @synchronized (self) {
        if (self.cancelled) return;
        self.cancelled = YES;
        assetTask = self.assetTask;
        storageTask = self.storageTask;
        self.assetTask = nil;
        self.storageTask = nil;
    }
    [assetTask cancel];
    [storageTask cancel];
}

- (BOOL)apolloSetAssetTask:(NSURLSessionTask *)task {
    @synchronized (self) {
        if (self.cancelled) {
            [task cancel];
            return NO;
        }
        self.assetTask = task;
        return YES;
    }
}

- (BOOL)apolloSetStorageTask:(NSURLSessionTask *)task {
    @synchronized (self) {
        if (self.cancelled) {
            [task cancel];
            return NO;
        }
        self.storageTask = task;
        return YES;
    }
}

- (void)apolloClearStorageTask:(NSURLSessionTask *)task {
    @synchronized (self) {
        if (self.storageTask == task) self.storageTask = nil;
    }
}

@end

@interface ApolloRedditMediaUploadProgressDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation ApolloRedditMediaUploadProgressDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    ApolloRedditMediaUploadOperation *operation = objc_getAssociatedObject(task, &kApolloRedditMediaUploadProgressOperationKey);
    ApolloRedditMediaUploadProgress handler = operation.progressHandler;
    if (!handler || totalBytesExpectedToSend <= 0) return;
    double progress = MIN(1.0, MAX(0.0, (double)totalBytesSent / (double)totalBytesExpectedToSend));
    handler(progress, totalBytesSent, totalBytesExpectedToSend);
}

@end

static NSURLSession *ApolloRedditMediaUploadProgressSession(void) {
    static NSURLSession *session = nil;
    static ApolloRedditMediaUploadProgressDelegate *delegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        delegate = [ApolloRedditMediaUploadProgressDelegate new];
        session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
    });
    return session;
}

BOOL ApolloIsImgurImageUploadRequest(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url) return NO;

    BOOL imgurHost = [url.host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [url.host isEqualToString:@"api.imgur.com"];
    return imgurHost && [url.path isEqualToString:@"/3/image"];
}

BOOL ApolloMediaMIMETypeIsVideo(NSString *mimeType) {
    return [mimeType isKindOfClass:[NSString class]] && [mimeType.lowercaseString hasPrefix:@"video/"];
}

NSString *ApolloMediaMIMETypeForFilename(NSString *filename, NSString *fallbackMIMEType) {
    NSString *extension = filename.pathExtension.lowercaseString;
    NSDictionary<NSString *, NSString *> *types = @{
        @"jpg": @"image/jpeg",
        @"jpeg": @"image/jpeg",
        @"png": @"image/png",
        @"gif": @"image/gif",
        @"mp4": @"video/mp4",
        @"mov": @"video/quicktime",
    };

    NSString *type = types[extension];
    if (type.length > 0) return type;
    if (fallbackMIMEType.length > 0 && ![fallbackMIMEType hasPrefix:@"multipart/"]) return fallbackMIMEType;
    return @"image/jpeg";
}

static NSString *ApolloDefaultExtensionForMIMEType(NSString *mimeType) {
    if ([mimeType isEqualToString:@"image/png"]) return @"png";
    if ([mimeType isEqualToString:@"image/gif"]) return @"gif";
    if ([mimeType isEqualToString:@"image/webp"]) return @"webp";
    if ([mimeType isEqualToString:@"image/heic"]) return @"heic";
    if ([mimeType isEqualToString:@"image/heif"]) return @"heif";
    if ([mimeType isEqualToString:@"video/mp4"]) return @"mp4";
    if ([mimeType isEqualToString:@"video/quicktime"]) return @"mov";
    return @"jpg";
}

static NSString *ApolloNormalizedFilename(NSString *filename, NSString *mimeType) {
    NSString *clean = filename.lastPathComponent;
    if (clean.length == 0) {
        clean = [@"apollo-upload" stringByAppendingPathExtension:ApolloDefaultExtensionForMIMEType(mimeType)];
    } else if (clean.pathExtension.length == 0) {
        clean = [clean stringByAppendingPathExtension:ApolloDefaultExtensionForMIMEType(mimeType)];
    }
    return clean;
}

static void ApolloAppendMultipartField(NSMutableData *body, NSString *boundary, NSString *name, NSString *value) {
    if (name.length == 0) return;
    if (!value) value = @"";

    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static void ApolloAppendMultipartFile(NSMutableData *body, NSString *boundary, NSString *fieldName, NSString *filename, NSString *mimeType, NSData *fileData) {
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fieldName, filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSData *ApolloMultipartBodyForFields(NSDictionary<NSString *, NSString *> *fields,
                                            NSData *fileData,
                                            NSString *filename,
                                            NSString *mimeType,
                                            NSString *boundary,
                                            BOOL includeFile) {
    NSMutableData *body = [NSMutableData data];
    for (NSString *key in fields) {
        ApolloAppendMultipartField(body, boundary, key, fields[key]);
    }
    if (includeFile) {
        ApolloAppendMultipartFile(body, boundary, @"file", filename, mimeType, fileData);
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    return body;
}

static BOOL ApolloOutputStreamWriteData(NSOutputStream *stream, NSData *data, NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        NSInteger written = [stream write:bytes maxLength:remaining];
        if (written <= 0) {
            if (error) *error = stream.streamError ?: ApolloRedditUploadError(42, @"Could not write multipart upload body");
            return NO;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

static BOOL ApolloOutputStreamCopyFile(NSOutputStream *stream, NSURL *fileURL, NSError **error) {
    NSInputStream *input = [NSInputStream inputStreamWithURL:fileURL];
    [input open];
    if (input.streamStatus == NSStreamStatusError) {
        if (error) *error = input.streamError ?: ApolloRedditUploadError(43, @"Could not open upload file");
        [input close];
        return NO;
    }

    uint8_t buffer[256 * 1024];
    while (YES) {
        NSInteger read = [input read:buffer maxLength:sizeof(buffer)];
        if (read < 0) {
            if (error) *error = input.streamError ?: ApolloRedditUploadError(44, @"Could not read upload file");
            [input close];
            return NO;
        }
        if (read == 0) break;
        NSData *chunk = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)read freeWhenDone:NO];
        if (!ApolloOutputStreamWriteData(stream, chunk, error)) {
            [input close];
            return NO;
        }
    }
    [input close];
    return YES;
}

static unsigned long long ApolloFileSizeForURL(NSURL *fileURL) {
    NSNumber *fileSize = nil;
    [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
    if (![fileSize isKindOfClass:[NSNumber class]]) [fileURL getResourceValue:&fileSize forKey:NSURLTotalFileSizeKey error:nil];
    return [fileSize isKindOfClass:[NSNumber class]] ? fileSize.unsignedLongLongValue : 0;
}

static NSURL *ApolloMultipartBodyFileForFields(NSDictionary<NSString *, NSString *> *fields,
                                               NSData *fileData,
                                               NSURL *fileURL,
                                               NSString *filename,
                                               NSString *mimeType,
                                               NSString *boundary,
                                               unsigned long long *outLength,
                                               NSError **error) {
    NSString *name = [[@"apollo-reddit-upload-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:@"multipart"];
    NSURL *bodyURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSOutputStream *stream = [NSOutputStream outputStreamWithURL:bodyURL append:NO];
    [stream open];
    if (stream.streamStatus == NSStreamStatusError) {
        if (error) *error = stream.streamError ?: ApolloRedditUploadError(45, @"Could not create multipart upload body");
        [stream close];
        return nil;
    }

    BOOL ok = YES;
    for (NSString *key in fields) {
        NSString *value = fields[key] ?: @"";
        NSString *field = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, key, value];
        ok = ApolloOutputStreamWriteData(stream, [field dataUsingEncoding:NSUTF8StringEncoding], error);
        if (!ok) break;
    }
    if (ok) {
        NSString *header = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, filename, mimeType];
        ok = ApolloOutputStreamWriteData(stream, [header dataUsingEncoding:NSUTF8StringEncoding], error);
    }
    if (ok) {
        if (fileURL) ok = ApolloOutputStreamCopyFile(stream, fileURL, error);
        else ok = ApolloOutputStreamWriteData(stream, fileData ?: [NSData data], error);
    }
    if (ok) ok = ApolloOutputStreamWriteData(stream, [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding], error);

    [stream close];
    if (!ok || stream.streamStatus == NSStreamStatusError) {
        if (error && !*error) *error = stream.streamError ?: ApolloRedditUploadError(46, @"Could not finish multipart upload body");
        [[NSFileManager defaultManager] removeItemAtURL:bodyURL error:nil];
        return nil;
    }

    if (outLength) *outLength = ApolloFileSizeForURL(bodyURL);
    return bodyURL;
}

static NSString *ApolloBoundary(void) {
    return [@"ApolloBoundary-" stringByAppendingString:[NSUUID UUID].UUIDString];
}

@interface ApolloRedditS3XMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *currentElement;
@property (nonatomic, strong) NSMutableString *currentText;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, copy) NSString *errorCode;
@property (nonatomic, copy) NSString *errorMessage;
@end

@implementation ApolloRedditS3XMLParser
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"Location"] || [elementName isEqualToString:@"Code"] || [elementName isEqualToString:@"Message"]) {
        self.currentElement = elementName;
        self.currentText = [NSMutableString string];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (self.currentText) {
        [self.currentText appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (![elementName isEqualToString:self.currentElement]) return;

    NSString *value = [self.currentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([elementName isEqualToString:@"Location"]) {
        self.location = value;
    } else if ([elementName isEqualToString:@"Code"]) {
        self.errorCode = value;
    } else if ([elementName isEqualToString:@"Message"]) {
        self.errorMessage = value;
    }
    self.currentElement = nil;
    self.currentText = nil;
}
@end

static NSURL *ApolloLocationURLFromS3Response(NSData *data, NSError **error) {
    ApolloRedditS3XMLParser *delegate = [ApolloRedditS3XMLParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;

    if (![parser parse]) {
        if (error) *error = parser.parserError ?: ApolloRedditUploadError(40, @"Could not parse Reddit upload response");
        return nil;
    }

    if (delegate.location.length == 0) {
        NSString *message = delegate.errorMessage.length > 0 ? delegate.errorMessage : @"Reddit upload response did not include a media URL";
        if (delegate.errorCode.length > 0) {
            message = [NSString stringWithFormat:@"%@: %@", delegate.errorCode, message];
        }
        if (error) *error = ApolloRedditUploadError(41, message);
        return nil;
    }

    NSString *decoded = delegate.location.stringByRemovingPercentEncoding ?: delegate.location;
    return [NSURL URLWithString:decoded];
}

NSData *ApolloSyntheticImgurUploadResponseData(NSURL *mediaURL, NSString *mimeType) {
    NSString *mediaID = mediaURL.lastPathComponent.length > 0 ? mediaURL.lastPathComponent : [NSUUID UUID].UUIDString;
    NSString *resolvedMIMEType = mimeType ?: @"image/jpeg";
    NSString *link = mediaURL.absoluteString ?: @"";
    BOOL isVideo = ApolloMediaMIMETypeIsVideo(resolvedMIMEType);
    BOOL isAnimatedImage = [resolvedMIMEType isEqualToString:@"image/gif"];
    NSDictionary *syntheticResponse = @{
        @"status": @200,
        @"success": @YES,
        @"data": @{
            @"id": mediaID,
            @"deletehash": mediaID,
            @"account_id": [NSNull null],
            @"account_url": [NSNull null],
            @"ad_type": [NSNull null],
            @"ad_url": [NSNull null],
            @"title": [NSNull null],
            @"description": [NSNull null],
            @"name": @"",
            @"type": resolvedMIMEType,
            @"width": @0,
            @"height": @0,
            @"size": @0,
            @"views": @0,
            @"section": [NSNull null],
            @"vote": [NSNull null],
            @"bandwidth": @0,
            @"animated": @(isVideo || isAnimatedImage),
            @"favorite": @NO,
            @"in_gallery": @NO,
            @"in_most_viral": @NO,
            @"has_sound": @(isVideo),
            @"is_ad": @NO,
            @"nsfw": [NSNull null],
            @"link": link,
            @"tags": @[],
            @"datetime": @0,
            @"mp4": isVideo ? link : @"",
            @"hls": isVideo ? link : @""
        }
    };
    return [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
}

// Shared second half of a Reddit media upload: POST the file (plus the lease's
// returned form fields) to the S3 endpoint the lease handed back, then parse the
// <Location> URL out of the S3 XML response and report it. assetID/webSocketURL
// are passed straight through to `completion` — the oauth lease supplies them; the
// keyless cookie lease (image_upload_s3.json) has none and passes nil. They're
// never needed to perform the upload itself, so nil is safe.
static void ApolloPerformRedditMediaS3Upload(NSURL *actionURL,
                                             NSDictionary<NSString *, NSString *> *fields,
                                             NSData *mediaData,
                                             NSURL *mediaFileURL,
                                             NSString *filename,
                                             NSString *mimeType,
                                             NSString *assetID,
                                             NSString *webSocketURL,
                                             ApolloRedditMediaUploadOperation *operation,
                                             ApolloRedditMediaUploadCompletion completion) {
    if (operation.cancelled) {
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }

    NSString *s3Boundary = ApolloBoundary();
    NSMutableURLRequest *s3Request = [NSMutableURLRequest requestWithURL:actionURL];
    s3Request.HTTPMethod = @"POST";
    [s3Request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:s3Boundary] forHTTPHeaderField:@"Content-Type"];
    NSError *bodyFileError = nil;
    unsigned long long s3BodyLength = 0;
    NSURL *s3BodyURL = ApolloMultipartBodyFileForFields(fields, mediaData, mediaFileURL, filename, mimeType, s3Boundary, &s3BodyLength, &bodyFileError);
    if (!s3BodyURL) {
        completion(nil, assetID, webSocketURL, bodyFileError ?: ApolloRedditUploadError(47, @"Could not prepare Reddit media storage upload"));
        return;
    }
    [s3Request setValue:[NSString stringWithFormat:@"%llu", s3BodyLength] forHTTPHeaderField:@"Content-Length"];

    ApolloLog(@"[RedditUpload] Uploading %@ to Reddit media storage", filename);

    __block NSURLSessionUploadTask *s3Task = nil;
    s3Task = [ApolloRedditMediaUploadProgressSession() uploadTaskWithRequest:s3Request fromFile:s3BodyURL completionHandler:^(NSData *s3Data, NSURLResponse *s3Response, NSError *s3Error) {
        [[NSFileManager defaultManager] removeItemAtURL:s3BodyURL error:nil];
        objc_setAssociatedObject(s3Task, &kApolloRedditMediaUploadProgressOperationKey, nil, OBJC_ASSOCIATION_ASSIGN);
        [operation apolloClearStorageTask:s3Task];
        if (operation.cancelled) {
            completion(nil, nil, nil, ApolloRedditUploadCancelledError());
            return;
        }
        if (s3Error) {
            completion(nil, assetID, webSocketURL, s3Error);
            return;
        }

        NSInteger s3StatusCode = [(NSHTTPURLResponse *)s3Response statusCode];
        if (![s3Response isKindOfClass:[NSHTTPURLResponse class]] || s3StatusCode < 200 || s3StatusCode >= 300 || s3Data.length == 0) {
            completion(nil, assetID, webSocketURL, ApolloRedditUploadError(s3StatusCode ?: 30, @"Reddit media storage upload failed"));
            return;
        }

        NSError *xmlError = nil;
        NSURL *imageURL = ApolloLocationURLFromS3Response(s3Data, &xmlError);
        if (!imageURL) {
            completion(nil, assetID, webSocketURL, xmlError);
            return;
        }

        ApolloLog(@"[RedditUpload] Uploaded media: %@ assetID=%@", imageURL.absoluteString, assetID ?: @"(none)");
        ApolloRedditMediaUploadProgress handler = operation.progressHandler;
        if (handler) handler(1.0, (int64_t)s3BodyLength, (int64_t)s3BodyLength);
        completion(imageURL, assetID, webSocketURL, nil);
    }];
    objc_setAssociatedObject(s3Task, &kApolloRedditMediaUploadProgressOperationKey, operation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![operation apolloSetStorageTask:s3Task]) {
        objc_setAssociatedObject(s3Task, &kApolloRedditMediaUploadProgressOperationKey, nil, OBJC_ASSOCIATION_ASSIGN);
        [[NSFileManager defaultManager] removeItemAtURL:s3BodyURL error:nil];
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }
    [s3Task resume];
}

static void ApolloRequestRedditMediaAsset(NSData *mediaData,
                                          NSURL *mediaFileURL,
                                          NSString *filename,
                                          NSString *mimeType,
                                          NSString *bearerToken,
                                          NSString *userAgent,
                                          ApolloRedditMediaUploadOperation *operation,
                                          ApolloRedditMediaUploadCompletion completion) {
    if (operation.cancelled) {
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://oauth.reddit.com/api/media/asset.json"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[@"Bearer " stringByAppendingString:bearerToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    NSString *boundary = ApolloBoundary();
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = ApolloMultipartBodyForFields(@{@"filepath": filename, @"mimetype": mimeType}, nil, filename, mimeType, boundary, NO);

    unsigned long long mediaLength = mediaFileURL ? ApolloFileSizeForURL(mediaFileURL) : (unsigned long long)mediaData.length;
    ApolloLog(@"[RedditUpload] Requesting media asset for %@ (%@, %@ bytes)", filename, mimeType, @(mediaLength));

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (operation.cancelled) {
            completion(nil, nil, nil, ApolloRedditUploadCancelledError());
            return;
        }
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }

        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || statusCode < 200 || statusCode >= 300 || data.length == 0) {
            completion(nil, nil, nil, ApolloRedditUploadError(statusCode ?: 20, @"Reddit did not provide upload fields"));
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil, jsonError ?: ApolloRedditUploadError(21, @"Reddit upload field response was not JSON"));
            return;
        }

        NSDictionary *args = [json[@"args"] isKindOfClass:[NSDictionary class]] ? json[@"args"] : nil;
        NSString *action = [args[@"action"] isKindOfClass:[NSString class]] ? args[@"action"] : nil;
        NSArray *fieldArray = [args[@"fields"] isKindOfClass:[NSArray class]] ? args[@"fields"] : nil;
        NSDictionary *asset = [json[@"asset"] isKindOfClass:[NSDictionary class]] ? json[@"asset"] : nil;
        NSString *assetID = [asset[@"asset_id"] isKindOfClass:[NSString class]] ? asset[@"asset_id"] : nil;
        NSString *webSocketURL = [asset[@"websocket_url"] isKindOfClass:[NSString class]] ? asset[@"websocket_url"] : nil;

        if (assetID.length == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(25, @"Reddit upload field response did not include an asset ID"));
            return;
        }

        if (action.length == 0 || fieldArray.count == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(22, @"Reddit upload field response was incomplete"));
            return;
        }

        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (id item in fieldArray) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
            NSString *value = [item[@"value"] isKindOfClass:[NSString class]] ? item[@"value"] : nil;
            if (name.length > 0 && value) fields[name] = value;
        }

        if (fields.count == 0) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(23, @"Reddit upload field response had no usable fields"));
            return;
        }

        NSString *actionURLString = [action hasPrefix:@"//"] ? [@"https:" stringByAppendingString:action] : action;
        NSURL *actionURL = [NSURL URLWithString:actionURLString];
        if (!actionURL) {
            completion(nil, nil, webSocketURL, ApolloRedditUploadError(24, @"Reddit upload field response had an invalid upload URL"));
            return;
        }

        ApolloPerformRedditMediaS3Upload(actionURL, fields, mediaData, mediaFileURL, filename, mimeType, assetID, webSocketURL, operation, completion);
    }];
    if (![operation apolloSetAssetTask:task]) {
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }
    [task resume];
}

// Percent-encode a value for an application/x-www-form-urlencoded body. Encodes
// everything outside the RFC 3986 unreserved set (so "/" in a MIME type and any
// odd filename characters are escaped).
static NSString *ApolloFormURLEncode(NSString *value) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// Keyless lease variant: instead of the oauth media/asset.json lease (which needs
// a real Bearer and 403s for cookie auth), POST the old-reddit web lease
// www.reddit.com/api/image_upload_s3.json with cookie + X-Modhash. This is
// Hydra's proven keyless upload path. Reddit returns the FLAT {action, fields}
// S3-presigned shape (no asset/asset_id/websocket_url), so the completion's
// assetID/webSocketURL are always nil — the S3 <Location> URL is the whole
// payload. Image only (the endpoint doesn't take video).
static void ApolloRequestRedditMediaAssetViaCookie(NSData *mediaData,
                                                   NSURL *mediaFileURL,
                                                   NSString *filename,
                                                   NSString *mimeType,
                                                   NSString *cookieHeader,
                                                   NSString *modhash,
                                                   NSString *userAgent,
                                                   ApolloRedditMediaUploadOperation *operation,
                                                   ApolloRedditMediaUploadCompletion completion) {
    if (operation.cancelled) {
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }

    // Probe fragment marks the request so the Web JSON chokepoint leaves it alone —
    // we set Cookie ourselves and re-pointing/counting it would be circular. The
    // fragment is stripped by NSURLSession before transmission; Reddit never sees it.
    NSURL *url = ApolloWebJSONProbeURL([NSURL URLWithString:@"https://www.reddit.com/api/image_upload_s3.json"]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    if (modhash.length > 0) [request setValue:modhash forHTTPHeaderField:@"X-Modhash"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPShouldHandleCookies = NO;
    NSString *body = [NSString stringWithFormat:@"filepath=%@&mimetype=%@&raw_json=1",
                      ApolloFormURLEncode(filename), ApolloFormURLEncode(mimeType)];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    unsigned long long mediaLength = mediaFileURL ? ApolloFileSizeForURL(mediaFileURL) : (unsigned long long)mediaData.length;
    ApolloLog(@"[RedditUpload] Requesting keyless web media lease for %@ (%@, %@ bytes)", filename, mimeType, @(mediaLength));

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (operation.cancelled) {
            completion(nil, nil, nil, ApolloRedditUploadCancelledError());
            return;
        }
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = http.statusCode;

        // Expired/revoked cookie → Reddit serves its 403 text/html block page.
        // Surface the same "session expired" prompt the chokepoint observer would
        // (this request carries the probe header, so it bypasses that observer).
        NSString *contentType = [[http.allHeaderFields[@"Content-Type"] description] lowercaseString] ?: @"";
        if (statusCode == 403 && [contentType containsString:@"text/html"]) {
            ApolloLog(@"[RedditUpload] Keyless web media lease got a 403 HTML block page — session likely expired");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloWebJSONSessionExpiredNotification object:nil];
            });
            completion(nil, nil, nil, ApolloRedditUploadError(403, @"Reddit web session expired — sign in again"));
            return;
        }

        if (!http || statusCode < 200 || statusCode >= 300 || data.length == 0) {
            completion(nil, nil, nil, ApolloRedditUploadError(statusCode ?: 20, @"Reddit did not provide upload fields"));
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil, jsonError ?: ApolloRedditUploadError(21, @"Reddit upload field response was not JSON"));
            return;
        }

        // Flat shape: action + fields live at the top level (no args/asset wrapper).
        NSString *action = [json[@"action"] isKindOfClass:[NSString class]] ? json[@"action"] : nil;
        NSArray *fieldArray = [json[@"fields"] isKindOfClass:[NSArray class]] ? json[@"fields"] : nil;
        if (action.length == 0 || fieldArray.count == 0) {
            completion(nil, nil, nil, ApolloRedditUploadError(22, @"Reddit upload field response was incomplete"));
            return;
        }

        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (id item in fieldArray) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? item[@"name"] : nil;
            NSString *value = [item[@"value"] isKindOfClass:[NSString class]] ? item[@"value"] : nil;
            if (name.length > 0 && value) fields[name] = value;
        }
        if (fields.count == 0) {
            completion(nil, nil, nil, ApolloRedditUploadError(23, @"Reddit upload field response had no usable fields"));
            return;
        }

        NSString *actionURLString = [action hasPrefix:@"//"] ? [@"https:" stringByAppendingString:action] : action;
        NSURL *actionURL = [NSURL URLWithString:actionURLString];
        if (!actionURL) {
            completion(nil, nil, nil, ApolloRedditUploadError(24, @"Reddit upload field response had an invalid upload URL"));
            return;
        }

        // No asset_id/websocket from the web lease — pass nil for both.
        ApolloPerformRedditMediaS3Upload(actionURL, fields, mediaData, mediaFileURL, filename, mimeType, nil, nil, operation, completion);
    }];
    if (![operation apolloSetAssetTask:task]) {
        completion(nil, nil, nil, ApolloRedditUploadCancelledError());
        return;
    }
    [task resume];
}

ApolloRedditMediaUploadOperation *ApolloUploadMediaDataToRedditCancellable(NSData *mediaData,
                                                                           NSString *filename,
                                                                           NSString *mimeType,
                                                                           NSString *bearerToken,
                                                                           NSString *userAgent,
                                                                           ApolloRedditMediaUploadProgress progressHandler,
                                                                           ApolloRedditMediaUploadCompletion completion) {
    ApolloRedditMediaUploadOperation *operation = [ApolloRedditMediaUploadOperation new];
    operation.progressHandler = progressHandler;
    ApolloRedditMediaUploadCompletion safeCompletion = completion ?: ^(__unused NSURL *mediaURL, __unused NSString *assetID, __unused NSString *webSocketURL, __unused NSError *error) {};
    if (mediaData.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(1, @"Media data was empty"));
        return operation;
    }
    if (bearerToken.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(2, @"Apollo has not captured a Reddit bearer token yet"));
        return operation;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
    NSString *resolvedFilename = ApolloNormalizedFilename(filename, resolvedMIMEType);
    NSString *resolvedUserAgent = userAgent.length > 0 ? userAgent : @"Apollo-Reborn/RedditMediaUpload";

    ApolloRequestRedditMediaAsset(mediaData, nil, resolvedFilename, resolvedMIMEType, bearerToken, resolvedUserAgent, operation, safeCompletion);
    return operation;
}

ApolloRedditMediaUploadOperation *ApolloUploadMediaFileToRedditCancellable(NSURL *mediaFileURL,
                                                                           NSString *filename,
                                                                           NSString *mimeType,
                                                                           NSString *bearerToken,
                                                                           NSString *userAgent,
                                                                           ApolloRedditMediaUploadProgress progressHandler,
                                                                           ApolloRedditMediaUploadCompletion completion) {
    ApolloRedditMediaUploadOperation *operation = [ApolloRedditMediaUploadOperation new];
    operation.progressHandler = progressHandler;
    ApolloRedditMediaUploadCompletion safeCompletion = completion ?: ^(__unused NSURL *mediaURL, __unused NSString *assetID, __unused NSString *webSocketURL, __unused NSError *error) {};
    unsigned long long fileSize = ApolloFileSizeForURL(mediaFileURL);
    if (![mediaFileURL isKindOfClass:[NSURL class]] || !mediaFileURL.isFileURL || fileSize == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(1, @"Media file was empty"));
        return operation;
    }
    if (bearerToken.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(2, @"Apollo has not captured a Reddit bearer token yet"));
        return operation;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename ?: mediaFileURL.lastPathComponent, mimeType);
    NSString *resolvedFilename = ApolloNormalizedFilename(filename.length > 0 ? filename : mediaFileURL.lastPathComponent, resolvedMIMEType);
    NSString *resolvedUserAgent = userAgent.length > 0 ? userAgent : @"Apollo-Reborn/RedditMediaUpload";

    ApolloRequestRedditMediaAsset(nil, mediaFileURL, resolvedFilename, resolvedMIMEType, bearerToken, resolvedUserAgent, operation, safeCompletion);
    return operation;
}

ApolloRedditMediaUploadOperation *ApolloUploadMediaDataToRedditViaCookieCancellable(NSData *mediaData,
                                                                                    NSString *filename,
                                                                                    NSString *mimeType,
                                                                                    NSString *cookieHeader,
                                                                                    NSString *modhash,
                                                                                    NSString *userAgent,
                                                                                    ApolloRedditMediaUploadProgress progressHandler,
                                                                                    ApolloRedditMediaUploadCompletion completion) {
    ApolloRedditMediaUploadOperation *operation = [ApolloRedditMediaUploadOperation new];
    operation.progressHandler = progressHandler;
    ApolloRedditMediaUploadCompletion safeCompletion = completion ?: ^(__unused NSURL *mediaURL, __unused NSString *assetID, __unused NSString *webSocketURL, __unused NSError *error) {};
    if (mediaData.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(1, @"Media data was empty"));
        return operation;
    }
    if (cookieHeader.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(2, @"No Reddit web session cookie available"));
        return operation;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
    NSString *resolvedFilename = ApolloNormalizedFilename(filename, resolvedMIMEType);
    NSString *resolvedUserAgent = userAgent.length > 0 ? userAgent : @"Apollo-Reborn/RedditMediaUpload";

    ApolloRequestRedditMediaAssetViaCookie(mediaData, nil, resolvedFilename, resolvedMIMEType, cookieHeader, modhash, resolvedUserAgent, operation, safeCompletion);
    return operation;
}

ApolloRedditMediaUploadOperation *ApolloUploadMediaFileToRedditViaCookieCancellable(NSURL *mediaFileURL,
                                                                                    NSString *filename,
                                                                                    NSString *mimeType,
                                                                                    NSString *cookieHeader,
                                                                                    NSString *modhash,
                                                                                    NSString *userAgent,
                                                                                    ApolloRedditMediaUploadProgress progressHandler,
                                                                                    ApolloRedditMediaUploadCompletion completion) {
    ApolloRedditMediaUploadOperation *operation = [ApolloRedditMediaUploadOperation new];
    operation.progressHandler = progressHandler;
    ApolloRedditMediaUploadCompletion safeCompletion = completion ?: ^(__unused NSURL *mediaURL, __unused NSString *assetID, __unused NSString *webSocketURL, __unused NSError *error) {};
    unsigned long long fileSize = ApolloFileSizeForURL(mediaFileURL);
    if (![mediaFileURL isKindOfClass:[NSURL class]] || !mediaFileURL.isFileURL || fileSize == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(1, @"Media file was empty"));
        return operation;
    }
    if (cookieHeader.length == 0) {
        safeCompletion(nil, nil, nil, ApolloRedditUploadError(2, @"No Reddit web session cookie available"));
        return operation;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename ?: mediaFileURL.lastPathComponent, mimeType);
    NSString *resolvedFilename = ApolloNormalizedFilename(filename.length > 0 ? filename : mediaFileURL.lastPathComponent, resolvedMIMEType);
    NSString *resolvedUserAgent = userAgent.length > 0 ? userAgent : @"Apollo-Reborn/RedditMediaUpload";

    ApolloRequestRedditMediaAssetViaCookie(nil, mediaFileURL, resolvedFilename, resolvedMIMEType, cookieHeader, modhash, resolvedUserAgent, operation, safeCompletion);
    return operation;
}

void ApolloUploadMediaDataToReddit(NSData *mediaData,
                                  NSString *filename,
                                  NSString *mimeType,
                                  NSString *bearerToken,
                                  NSString *userAgent,
                                  ApolloRedditMediaUploadCompletion completion) {
    ApolloUploadMediaDataToRedditCancellable(mediaData, filename, mimeType, bearerToken, userAgent, nil, completion);
}

void ApolloUploadImageDataToReddit(NSData *imageData,
                                   NSString *filename,
                                   NSString *mimeType,
                                   NSString *bearerToken,
                                   NSString *userAgent,
                                   ApolloRedditMediaUploadCompletion completion) {
    ApolloUploadMediaDataToReddit(imageData, filename, mimeType, bearerToken, userAgent, completion);
}
