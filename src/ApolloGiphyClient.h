#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloGiphyGIF : NSObject

@property (nonatomic, copy) NSString *gifID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *pageURL;
@property (nonatomic, copy, nullable) NSURL *previewURL;
@property (nonatomic, copy, nullable) NSURL *downloadURL;

@end

typedef void (^ApolloGiphyDownloadCompletion)(NSData *_Nullable data, NSError *_Nullable error);
typedef void (^ApolloGiphyFetchCompletion)(NSArray<ApolloGiphyGIF *> *gifs, BOOL hasMore, NSError *_Nullable error);

@interface ApolloGiphyClient : NSObject

+ (NSString *)configuredAPIKey;

+ (void)downloadGIFData:(ApolloGiphyGIF *)gif
             completion:(ApolloGiphyDownloadCompletion)completion;

+ (nullable NSURLSessionDataTask *)fetchTrendingWithOffset:(NSUInteger)offset
                                                completion:(ApolloGiphyFetchCompletion)completion;

+ (nullable NSURLSessionDataTask *)searchWithQuery:(NSString *)query
                                            offset:(NSUInteger)offset
                                        completion:(ApolloGiphyFetchCompletion)completion;

@end

NS_ASSUME_NONNULL_END
