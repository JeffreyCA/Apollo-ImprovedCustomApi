// ApolloTweetBuddy.xm
//
// Vendored from DeltAndy123's PR #215:
// https://github.com/Apollo-Reborn/Apollo-Reborn/pull/215
//
// Intercepts Apollo's TweetBuddy network requests to apollogur.download (now
// defunct) and replaces them with live fetches against X/Twitter's internal
// GraphQL API. Gated by the Rich Link Previews toggle so users can disable all
// extra link-preview networking in one place.

#import <Foundation/Foundation.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

static NSString *const kApolloTweetBaseURL = @"https://apollogur.download/api/tweet/";
static NSString *const kXHomepageURL = @"https://x.com/";
static NSString *const kXGraphQLURL = @"https://api.x.com/graphql/zy39CwTyYhU-_0LP7dljjg/TweetResultByRestId";
static NSString *const kXBearerToken = @"Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
static NSString *const kHandledKey = @"ApolloTweetProtocolHandled";
static const NSTimeInterval kGuestTokenMaxAge = 9000.0;

static NSString *sGuestToken = nil;
static NSDate *sTokenFetchDate = nil;
static dispatch_queue_t sTokenQueue;
static dispatch_queue_t sTokenDeliveryQueue;
static NSMutableArray<void (^)(NSString *, NSError *)> *sTokenCompletions;
static BOOL sTokenFetchInFlight = NO;

static NSDictionary *ApolloTweetBuddyTransformResult(NSDictionary *result) {
    NSDictionary *legacy = result[@"legacy"];
    NSDictionary *userResult = result[@"core"][@"user_results"][@"result"];
    NSDictionary *userCore = userResult[@"core"];
    NSString *avatarURL = userResult[@"avatar"][@"image_url"] ?: @"";

    NSDictionary *user = @{
        @"name": userCore[@"name"] ?: @"",
        @"screen_name": userCore[@"screen_name"] ?: @"",
        @"profile_image_url_https": avatarURL,
        @"verified": userResult[@"is_blue_verified"] ?: @NO,
    };

    return @{
        @"full_text": legacy[@"full_text"] ?: @"",
        @"user": user,
        @"entities": legacy[@"entities"] ?: @{},
    };
}

@interface ApolloTweetProtocol : NSURLProtocol
@end

@implementation ApolloTweetProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (sLinkPreviewBodyMode == ApolloLinkPreviewModeOff && sLinkPreviewCommentsMode == ApolloLinkPreviewModeOff) return NO;
    if (![request.URL.absoluteString hasPrefix:kApolloTweetBaseURL]) return NO;
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *tweetId = self.request.URL.lastPathComponent;
    id<NSURLProtocolClient> client = self.client;
    NSURLRequest *origRequest = self.request;

    ApolloLog(@"[TweetBuddy] intercepted request for tweet %@", tweetId);

    [ApolloTweetProtocol resolveGuestToken:^(NSString *token, NSError *tokenError) {
        if (!token) {
            ApolloLog(@"[TweetBuddy] guest token fetch failed: %@", tokenError.localizedDescription);
            NSError *error = tokenError ?: [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                               code:-1
                                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to obtain guest token"}];
            [client URLProtocol:self didFailWithError:error];
            return;
        }

        [ApolloTweetProtocol fetchTweet:tweetId guestToken:token completion:^(NSDictionary *tweetDict, NSError *fetchError) {
            if (!tweetDict) {
                ApolloLog(@"[TweetBuddy] GraphQL fetch failed: %@", fetchError.localizedDescription);
                [client URLProtocol:self didFailWithError:fetchError];
                return;
            }

            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:tweetDict options:0 error:nil];
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:origRequest.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];

            [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [client URLProtocol:self didLoadData:jsonData];
            [client URLProtocolDidFinishLoading:self];
            ApolloLog(@"[TweetBuddy] delivered synthetic v1.1 response for tweet %@", tweetId);
        }];
    }];
}

- (void)stopLoading {}

+ (void)resolveGuestToken:(void (^)(NSString *token, NSError *error))completion {
    if (!completion) return;
    dispatch_async(sTokenQueue, ^{
        if (sGuestToken && sTokenFetchDate && [[NSDate date] timeIntervalSinceDate:sTokenFetchDate] < kGuestTokenMaxAge) {
            NSString *token = sGuestToken;
            dispatch_async(sTokenDeliveryQueue, ^{
                completion(token, nil);
            });
            return;
        }

        [sTokenCompletions addObject:[completion copy]];
        if (sTokenFetchInFlight) return;
        sTokenFetchInFlight = YES;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kXHomepageURL]];
        [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:request];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *token = nil;
            NSError *finalError = error;
            if (!finalError && data.length > 0) {
                NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"gt=([0-9]+);" options:0 error:nil];
                NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
                if (match && match.numberOfRanges >= 2) {
                    token = [html substringWithRange:[match rangeAtIndex:1]];
                } else {
                    finalError = [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                     code:-2
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Could not find gt= in x.com HTML"}];
                }
            } else if (!finalError) {
                finalError = [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                 code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"x.com returned an empty response"}];
            }

            dispatch_async(sTokenQueue, ^{
                if (token.length > 0) {
                    sGuestToken = token;
                    sTokenFetchDate = [NSDate date];
                }
                NSArray<void (^)(NSString *, NSError *)> *callbacks = [sTokenCompletions copy];
                [sTokenCompletions removeAllObjects];
                sTokenFetchInFlight = NO;
                // Never invoke foreign completion blocks while the token-state
                // owner queue is occupied.
                dispatch_async(sTokenDeliveryQueue, ^{
                    for (void (^callback)(NSString *, NSError *) in callbacks) {
                        callback(token, finalError);
                    }
                });
            });
        }] resume];
    });
}

+ (void)fetchTweet:(NSString *)tweetId
        guestToken:(NSString *)guestToken
        completion:(void (^)(NSDictionary *tweetDict, NSError *error))completion {
    NSString *variables = [NSString stringWithFormat:@"{\"tweetId\":\"%@\",\"withCommunity\":false,\"includePromotedContent\":false,\"withVoice\":false}", tweetId];
    NSString *features = @"{\"creator_subscriptions_tweet_preview_api_enabled\":true,\"view_counts_everywhere_api_enabled\":true}";

    NSURLComponents *components = [NSURLComponents componentsWithString:kXGraphQLURL];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"variables" value:variables],
        [NSURLQueryItem queryItemWithName:@"features" value:features],
    ];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:kXBearerToken forHTTPHeaderField:@"authorization"];
    [request setValue:guestToken forHTTPHeaderField:@"x-guest-token"];
    [request setValue:@"application/json" forHTTPHeaderField:@"content-type"];
    [request setValue:@"https://x.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://x.com/" forHTTPHeaderField:@"Referer"];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:request];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion(nil, error);
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
            dispatch_async(sTokenQueue, ^{
                sGuestToken = nil;
                sTokenFetchDate = nil;
            });
            completion(nil, [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                code:httpResponse.statusCode
                                            userInfo:@{NSLocalizedDescriptionKey: @"Guest token rejected; will refresh on retry"}]);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSDictionary *result = json[@"data"][@"tweetResult"][@"result"];
        if (!result) {
            completion(nil, jsonError ?: [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                            code:-3
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unexpected GraphQL response structure"}]);
            return;
        }

        completion(ApolloTweetBuddyTransformResult(result), nil);
    }] resume];
}

@end

%hook NSURLSessionConfiguration

+ (instancetype)defaultSessionConfiguration {
    NSURLSessionConfiguration *configuration = %orig;
    if (sLinkPreviewBodyMode == ApolloLinkPreviewModeOff && sLinkPreviewCommentsMode == ApolloLinkPreviewModeOff) return configuration;

    NSMutableArray *protocols = [NSMutableArray arrayWithArray:configuration.protocolClasses ?: @[]];
    if (![protocols containsObject:[ApolloTweetProtocol class]]) {
        [protocols insertObject:[ApolloTweetProtocol class] atIndex:0];
        configuration.protocolClasses = protocols;
    }
    return configuration;
}

%end

%ctor {
    sTokenCompletions = [NSMutableArray new];
    sTokenQueue = dispatch_queue_create("com.apollo.tweetbuddy.tokenqueue", DISPATCH_QUEUE_SERIAL);
    // Keep completion ordering serial, but separate from token-state ownership.
    sTokenDeliveryQueue = dispatch_queue_create("com.apollo.tweetbuddy.token-delivery", DISPATCH_QUEUE_SERIAL);
    ApolloLog(@"[TweetBuddy] ApolloTweetProtocol ready");
}
