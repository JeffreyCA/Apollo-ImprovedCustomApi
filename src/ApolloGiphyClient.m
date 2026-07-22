#import "ApolloGiphyClient.h"
#import "UserDefaultConstants.h"

static const NSUInteger kApolloGiphyPageSize = 25;

@implementation ApolloGiphyGIF
@end

@implementation ApolloGiphyClient

+ (NSString *)configuredAPIKey {
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyGiphyAPIKey];
    return key.length > 0 ? key : @"";
}

+ (NSURL *)imageURLFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *urlString = dict[@"url"];
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    return [NSURL URLWithString:urlString];
}

+ (void)downloadGIFData:(ApolloGiphyGIF *)gif completion:(ApolloGiphyDownloadCompletion)completion {
    if (!completion) return;
    if (!gif.downloadURL) {
        completion(nil, [NSError errorWithDomain:@"ApolloGiphy" code:4 userInfo:@{NSLocalizedDescriptionKey: @"GIF download URL unavailable"}]);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:gif.downloadURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, error);
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (http && http.statusCode >= 400) {
                completion(nil, [NSError errorWithDomain:@"ApolloGiphy" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: @"GIF download failed"}]);
                return;
            }
            if (data.length == 0) {
                completion(nil, [NSError errorWithDomain:@"ApolloGiphy" code:5 userInfo:@{NSLocalizedDescriptionKey: @"GIF download returned empty data"}]);
                return;
            }
            completion(data, nil);
        });
    }];
    [task resume];
}

+ (NSURL *)requestURLForPath:(NSString *)path queryItems:(NSArray<NSURLQueryItem *> *)extraItems {
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://api.giphy.com/v1/gifs/%@", path]];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:extraItems ?: @[]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"api_key" value:[self configuredAPIKey]]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)kApolloGiphyPageSize]]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"rating" value:@"pg-13"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"bundle" value:@"messaging_non_clips"]];
    components.queryItems = items;
    return components.URL;
}

+ (ApolloGiphyGIF *)gifFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;

    NSString *gifID = dict[@"id"];
    if (![gifID isKindOfClass:[NSString class]] || gifID.length == 0) return nil;

    ApolloGiphyGIF *gif = [ApolloGiphyGIF new];
    gif.gifID = gifID;
    gif.title = [dict[@"title"] isKindOfClass:[NSString class]] ? dict[@"title"] : @"";

    NSString *pageURL = dict[@"url"];
    if ([pageURL isKindOfClass:[NSString class]] && pageURL.length > 0) {
        gif.pageURL = pageURL;
    } else {
        gif.pageURL = [NSString stringWithFormat:@"https://giphy.com/gifs/%@", gifID];
    }

    NSDictionary *images = [dict[@"images"] isKindOfClass:[NSDictionary class]] ? dict[@"images"] : nil;
    NSDictionary *original = [images[@"original"] isKindOfClass:[NSDictionary class]] ? images[@"original"] : nil;
    NSDictionary *downsizedMedium = [images[@"downsized_medium"] isKindOfClass:[NSDictionary class]] ? images[@"downsized_medium"] : nil;
    NSDictionary *fixedWidth = [images[@"fixed_width"] isKindOfClass:[NSDictionary class]] ? images[@"fixed_width"] : nil;
    NSDictionary *fixedHeightSmall = [images[@"fixed_height_small"] isKindOfClass:[NSDictionary class]] ? images[@"fixed_height_small"] : nil;

    gif.downloadURL = [self imageURLFromDictionary:original]
        ?: [self imageURLFromDictionary:downsizedMedium]
        ?: [self imageURLFromDictionary:fixedWidth]
        ?: [self imageURLFromDictionary:fixedHeightSmall];

    NSString *preview = fixedWidth[@"url"];
    if (![preview isKindOfClass:[NSString class]] || preview.length == 0) {
        preview = fixedHeightSmall[@"url"];
    }
    if ([preview isKindOfClass:[NSString class]] && preview.length > 0) {
        gif.previewURL = [NSURL URLWithString:preview];
    }

    return gif;
}

+ (void)parseResponseData:(NSData *)data
               completion:(ApolloGiphyFetchCompletion)completion {
    if (!completion) return;

    if (data.length == 0) {
        completion(@[], NO, [NSError errorWithDomain:@"ApolloGiphy" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Empty response"}]);
        return;
    }

    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![root isKindOfClass:[NSDictionary class]]) {
        completion(@[], NO, jsonError ?: [NSError errorWithDomain:@"ApolloGiphy" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
        return;
    }

    NSDictionary *meta = [root[@"meta"] isKindOfClass:[NSDictionary class]] ? root[@"meta"] : nil;
    NSNumber *status = meta[@"status"];
    if (status.integerValue != 200) {
        NSString *message = [meta[@"msg"] isKindOfClass:[NSString class]] ? meta[@"msg"] : @"Giphy request failed";
        completion(@[], NO, [NSError errorWithDomain:@"ApolloGiphy" code:status.integerValue userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }

    NSArray *dataArray = [root[@"data"] isKindOfClass:[NSArray class]] ? root[@"data"] : @[];
    NSMutableArray<ApolloGiphyGIF *> *gifs = [NSMutableArray arrayWithCapacity:dataArray.count];
    for (id item in dataArray) {
        ApolloGiphyGIF *gif = [self gifFromDictionary:item];
        if (gif) [gifs addObject:gif];
    }

    NSDictionary *pagination = [root[@"pagination"] isKindOfClass:[NSDictionary class]] ? root[@"pagination"] : nil;
    NSNumber *totalCount = pagination[@"total_count"];
    NSNumber *offset = pagination[@"offset"];
    NSNumber *count = pagination[@"count"];
    BOOL hasMore = NO;
    if (totalCount && offset && count) {
        hasMore = (offset.integerValue + count.integerValue) < totalCount.integerValue;
    } else {
        hasMore = gifs.count >= kApolloGiphyPageSize;
    }

    completion(gifs, hasMore, nil);
}

+ (NSURLSessionDataTask *)performGET:(NSURL *)url completion:(ApolloGiphyFetchCompletion)completion {
    if (!completion) return nil;
    if ([self configuredAPIKey].length == 0) {
        completion(@[], NO, [NSError errorWithDomain:@"ApolloGiphy" code:401 userInfo:@{NSLocalizedDescriptionKey: @"Giphy API key not configured"}]);
        return nil;
    }
    if (!url) {
        completion(@[], NO, [NSError errorWithDomain:@"ApolloGiphy" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid request URL"}]);
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20.0;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(@[], NO, error);
                return;
            }
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSInteger code = http ? http.statusCode : 6;
                completion(@[], NO, [NSError errorWithDomain:@"ApolloGiphy" code:code
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Giphy request failed"}]);
                return;
            }
            [self parseResponseData:data completion:completion];
        });
    }];
    [task resume];
    return task;
}

+ (NSURLSessionDataTask *)fetchTrendingWithOffset:(NSUInteger)offset completion:(ApolloGiphyFetchCompletion)completion {
    NSURL *url = [self requestURLForPath:@"trending" queryItems:@[
        [NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%lu", (unsigned long)offset]],
    ]];
    return [self performGET:url completion:completion];
}

+ (NSURLSessionDataTask *)searchWithQuery:(NSString *)query offset:(NSUInteger)offset completion:(ApolloGiphyFetchCompletion)completion {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return [self fetchTrendingWithOffset:offset completion:completion];
    }

    NSURL *url = [self requestURLForPath:@"search" queryItems:@[
        [NSURLQueryItem queryItemWithName:@"q" value:trimmed],
        [NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%lu", (unsigned long)offset]],
    ]];
    return [self performGET:url completion:completion];
}

@end
