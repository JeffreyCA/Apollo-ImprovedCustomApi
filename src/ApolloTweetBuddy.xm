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
#import <mach-o/dyld.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// Minimal surface for Apollo's vote-count base class. RDKLink and RDKComment
// both inherit `score` from RDKVotable without overriding it, so hooking
// RDKVotable covers posts and comments alike.
@interface RDKVotable : NSObject
@property (nonatomic) long long score;
@end

static NSString *const kApolloTweetBaseURL = @"https://apollogur.download/api/tweet/";
static NSString *const kXGuestActivateURL = @"https://api.x.com/1.1/guest/activate.json";
static NSString *const kXGraphQLURL = @"https://api.x.com/graphql/zy39CwTyYhU-_0LP7dljjg/TweetResultByRestId";
static NSString *const kXBearerToken = @"Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA";
static NSString *const kHandledKey = @"ApolloTweetProtocolHandled";
static const NSTimeInterval kGuestTokenMaxAge = 9000.0;

static NSString *sGuestToken = nil;
static NSDate *sTokenFetchDate = nil;
static dispatch_queue_t sTokenQueue;

// Apollo only issues the apollogur tweet fetch this protocol intercepts when
// the post/comment's score is > 40. That gate lives inline in three compiled
// Swift render paths, each reading -[RDKVotable score] via objc_msgSend right
// before comparing it:
//   - CompactPostThumbnailNode (sub_1006f0f60): cmp x0, #0x29  -> b.lt skip
//   - RichMediaNode            (sub_100587790): cmp x0, #0x28  -> cset w22, gt
//   - CommentsHeaderCellNode   (sub_100568f58): cmp x0, #0x28  -> cset w23, gt
// (the first two cover the post feeds; the third is the post detail page's
// header cell, which has its own separate gate feeding the same link-button
// builder.)
// objc_msgSend tail-calls into -score, so __builtin_return_address(0) inside
// the hooked getter equals the instruction right after each `bl objc_msgSend`
// above -- i.e. the `cmp` itself. We match on those three exact addresses and
// report a score of 41 (just enough to pass all gates) only there, leaving
// every other caller (including the on-screen vote count) untouched.
//
// Addresses are Hopper file offsets (preferred base 0x100000000) for the
// pinned Apollo 1.15.11 (285) binary this tweak ships against.
static const uintptr_t kGateCompactThumbnailCmp = 0x1006f41acULL; // sub_1006f0f60: cmp x0, #0x29
static const uintptr_t kGateRichMediaCmp = 0x100587accULL;        // sub_100587790: cmp x0, #0x28
static const uintptr_t kGateCommentsHeaderCmp = 0x1005697e8ULL;   // sub_100568f58: cmp x0, #0x28

// Expected instruction encodings at the gate sites above, verified once
// at startup so a re-pinned/altered binary safely disables this fix instead
// of comparing against the wrong address.
static const uint32_t kGateCompactThumbnailCmpInsn = 0xF100A41FU; // cmp x0, #0x29
static const uint32_t kGateRichMediaCmpInsn = 0xF100A01FU;        // cmp x0, #0x28
static const uint32_t kGateCommentsHeaderCmpInsn = 0xF100A01FU;   // cmp x0, #0x28

static intptr_t sApolloSlide = 0;
static BOOL sUpvoteGateBypassArmed = NO;

// Image 0 as seen by _dyld_get_image_*() is the first-loaded image, which for
// an injected dylib is the dylib itself, not Apollo's main executable. Find
// Apollo's image explicitly by matching the main bundle's executable path.
static intptr_t ApolloTweetBuddyFindApolloSlide(void) {
    const char *apolloPath = [[NSBundle mainBundle] executablePath].fileSystemRepresentation;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, apolloPath) == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static uintptr_t ApolloTweetBuddyGateAddress(uintptr_t hopperAddr) {
    return (uintptr_t)((intptr_t)hopperAddr + sApolloSlide);
}

static BOOL ApolloTweetBuddyVerifyGateInstruction(uintptr_t hopperAddr, uint32_t expected) {
    uint32_t actual = *(const uint32_t *)ApolloTweetBuddyGateAddress(hopperAddr);
    return actual == expected;
}

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
    dispatch_async(sTokenQueue, ^{
        if (sGuestToken && sTokenFetchDate && [[NSDate date] timeIntervalSinceDate:sTokenFetchDate] < kGuestTokenMaxAge) {
            completion(sGuestToken, nil);
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kXGuestActivateURL]];
        request.HTTPMethod = @"POST";
        [request setValue:kXBearerToken forHTTPHeaderField:@"authorization"];
        // Also hands back guest_id / personalization_id tracking cookies; keep
        // them out of Apollo's shared jar.
        request.HTTPShouldHandleCookies = NO;
        [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:request];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) {
                completion(nil, error);
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id rawToken = [json isKindOfClass:[NSDictionary class]] ? json[@"guest_token"] : nil;
            // A string today; tolerate a bare number rather than failing the fetch.
            NSString *token = nil;
            if ([rawToken isKindOfClass:[NSString class]]) {
                token = rawToken;
            } else if ([rawToken isKindOfClass:[NSNumber class]]) {
                token = [rawToken stringValue];
            }
            if (token.length == 0) {
                completion(nil, [NSError errorWithDomain:@"ApolloTweetProtocol"
                                                    code:-2
                                                userInfo:@{NSLocalizedDescriptionKey: @"No guest_token in guest/activate.json response"}]);
                return;
            }

            dispatch_async(sTokenQueue, ^{
                sGuestToken = token;
                sTokenFetchDate = [NSDate date];
            });
            completion(token, nil);
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
    // Sets the same tracking cookies as the activate call, on every preview.
    request.HTTPShouldHandleCookies = NO;
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

%hook RDKVotable

// Apollo gates the apollogur tweet-preview fetch on score > 40. Inflate the
// score to 41 only when read from one of the three known gate sites, so
// previews render for tweet links regardless of vote count while the
// displayed vote count (and everything else) sees the real score.
- (long long)score {
    long long real = %orig;

    if (!sUpvoteGateBypassArmed) return real;
    if (sLinkPreviewBodyMode == ApolloLinkPreviewModeOff && sLinkPreviewCommentsMode == ApolloLinkPreviewModeOff) return real;
    if (real > 40) return real;

    uintptr_t ret = (uintptr_t)__builtin_return_address(0);
    if (ret == ApolloTweetBuddyGateAddress(kGateCompactThumbnailCmp) ||
        ret == ApolloTweetBuddyGateAddress(kGateRichMediaCmp) ||
        ret == ApolloTweetBuddyGateAddress(kGateCommentsHeaderCmp)) {
        return 41;
    }

    return real;
}

%end

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
    sTokenQueue = dispatch_queue_create("com.apollo.tweetbuddy.tokenqueue", DISPATCH_QUEUE_SERIAL);

    sApolloSlide = ApolloTweetBuddyFindApolloSlide();

    sUpvoteGateBypassArmed = sApolloSlide != 0 &&
                             ApolloTweetBuddyVerifyGateInstruction(kGateCompactThumbnailCmp, kGateCompactThumbnailCmpInsn) &&
                             ApolloTweetBuddyVerifyGateInstruction(kGateRichMediaCmp, kGateRichMediaCmpInsn) &&
                             ApolloTweetBuddyVerifyGateInstruction(kGateCommentsHeaderCmp, kGateCommentsHeaderCmpInsn);
    if (!sUpvoteGateBypassArmed) {
        ApolloLog(@"[TweetBuddy] upvote gate bypass disabled: unexpected instructions at gate sites (binary mismatch?)");
    }

    ApolloLog(@"[TweetBuddy] ApolloTweetProtocol ready");
}
