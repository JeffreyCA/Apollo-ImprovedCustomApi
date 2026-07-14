#import <Foundation/Foundation.h>

@interface ApolloRedditMediaUploadOperation : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (atomic, assign, readonly, getter=isCancelled) BOOL cancelled;

@property (nonatomic, copy) void (^progressHandler)(double progress, int64_t bytesSent, int64_t totalBytesExpected);

- (void)cancel;

@end

#ifdef __cplusplus
extern "C" {
#endif

typedef void (^ApolloRedditMediaUploadCompletion)(NSURL *mediaURL, NSString *assetID, NSString *webSocketURL, NSError *error);
typedef void (^ApolloRedditMediaUploadProgress)(double progress, int64_t bytesSent, int64_t totalBytesExpected);

BOOL ApolloIsImgurImageUploadRequest(NSURLRequest *request);
NSString *ApolloMediaMIMETypeForFilename(NSString *filename, NSString *fallbackMIMEType);
BOOL ApolloMediaMIMETypeIsVideo(NSString *mimeType);
NSData *ApolloSyntheticImgurUploadResponseData(NSURL *mediaURL, NSString *mimeType);
ApolloRedditMediaUploadOperation *ApolloUploadMediaDataToRedditCancellable(NSData *mediaData,
                                                                           NSString *filename,
                                                                           NSString *mimeType,
                                                                           NSString *bearerToken,
                                                                           NSString *userAgent,
                                                                           ApolloRedditMediaUploadProgress progressHandler,
                                                                           ApolloRedditMediaUploadCompletion completion);
ApolloRedditMediaUploadOperation *ApolloUploadMediaFileToRedditCancellable(NSURL *mediaFileURL,
                                                                           NSString *filename,
                                                                           NSString *mimeType,
                                                                           NSString *bearerToken,
                                                                           NSString *userAgent,
                                                                           ApolloRedditMediaUploadProgress progressHandler,
                                                                           ApolloRedditMediaUploadCompletion completion);
// Keyless (Web JSON) variants: upload an image to Reddit using a harvested web
// session cookie + modhash instead of an OAuth bearer (POST www.reddit.com/api/
// image_upload_s3.json — Hydra's path). The completion's assetID/webSocketURL are
// always nil (the web lease returns none); the mediaURL is the real S3 Location.
// Image MIME types only.
ApolloRedditMediaUploadOperation *ApolloUploadMediaDataToRedditViaCookieCancellable(NSData *mediaData,
                                                                                    NSString *filename,
                                                                                    NSString *mimeType,
                                                                                    NSString *cookieHeader,
                                                                                    NSString *modhash,
                                                                                    NSString *userAgent,
                                                                                    ApolloRedditMediaUploadProgress progressHandler,
                                                                                    ApolloRedditMediaUploadCompletion completion);
ApolloRedditMediaUploadOperation *ApolloUploadMediaFileToRedditViaCookieCancellable(NSURL *mediaFileURL,
                                                                                    NSString *filename,
                                                                                    NSString *mimeType,
                                                                                    NSString *cookieHeader,
                                                                                    NSString *modhash,
                                                                                    NSString *userAgent,
                                                                                    ApolloRedditMediaUploadProgress progressHandler,
                                                                                    ApolloRedditMediaUploadCompletion completion);
void ApolloUploadMediaDataToReddit(NSData *mediaData,
                                   NSString *filename,
                                   NSString *mimeType,
                                  NSString *bearerToken,
                                  NSString *userAgent,
                                  ApolloRedditMediaUploadCompletion completion);
void ApolloUploadImageDataToReddit(NSData *imageData,
                                   NSString *filename,
                                   NSString *mimeType,
                                   NSString *bearerToken,
                                   NSString *userAgent,
                                   ApolloRedditMediaUploadCompletion completion);

#ifdef __cplusplus
}
#endif
