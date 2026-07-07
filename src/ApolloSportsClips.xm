// ApolloSportsClips.xm
//
// "Sports Clip Links Play Inline" — see ApolloSportsClipResolver.h for the
// full design. Three hooks:
//
//   1. NSRegularExpression initWithPattern: — widens Apollo's Streamable
//      recognition regex to also match sports-clip hosts, so their posts
//      classify as inline Streamable video everywhere (feed, comments header,
//      media viewer) with one hook. Chain-safe with ApolloMedia.xm's hook on
//      the same initializer: the resolver recognizes both the original pattern
//      and ApolloMedia's query-string replacement, whichever arrives first.
//
//   2. NSRegularExpression firstMatchInString: — Apollo extracts the shortcode
//      via firstMatchInString + rangeAtIndex:1 (binary-verified). When our
//      widened pattern matches a sports URL, record clipID -> host in the side
//      table so the network interceptor can recover provenance. The model's
//      URL is never rewritten, so copy-link / open-in-browser stay honest.
//
//   3. NSURLSession dataTaskWithURL:completionHandler: — Apollo's VideoClient
//      fetches api.streamable.com/videos/<code> (and /videos/<code>.json for
//      the thumbnail) through this exact method on its own session. For
//      registered sports ids, answer with synthesized Streamable-shaped JSON
//      instead of forwarding (the Tweak.xm Imgur-DDG fabrication technique:
//      route the real task at a fast-failing localhost URL and deliver the
//      synthetic payload from its completion). Real Streamable ids pass
//      through untouched.

#import "ApolloCommon.h"
#import "ApolloSportsClipResolver.h"
#import "UserDefaultConstants.h"

%hook NSRegularExpression

- (instancetype)initWithPattern:(NSString *)pattern
                        options:(NSRegularExpressionOptions)options
                          error:(NSError **)error {
    NSString *widened = ApolloSportsClipsWidenPatternIfNeeded(pattern);
    if (widened != pattern) {
        return %orig(widened, options, error);
    }
    return %orig;
}

- (NSTextCheckingResult *)firstMatchInString:(NSString *)string
                                     options:(NSMatchingOptions)options
                                       range:(NSRange)range {
    NSTextCheckingResult *result = %orig;
    if (result && result.numberOfRanges > 1 && ApolloSportsClipsIsWidenedPattern(self.pattern)) {
        NSRange idRange = [result rangeAtIndex:1];
        if (idRange.location != NSNotFound && NSMaxRange(idRange) <= string.length) {
            ApolloSportsClipsNoteRecognizedURL(string, [string substringWithRange:idRange]);
        }
    }
    return result;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (completionHandler && ApolloSportsClipsEnabled() &&
        [url.host isEqualToString:@"api.streamable.com"] && [url.path hasPrefix:@"/videos/"]) {
        NSString *code = url.lastPathComponent;
        if ([code.pathExtension isEqualToString:@"json"]) code = [code stringByDeletingPathExtension];

        if (ApolloSportsClipsHasID(code)) {
            ApolloLog(@"[SportsClips] intercepting VideoClient fetch %@", url.absoluteString);
            void (^handler)(NSData *, NSURLResponse *, NSError *) = [completionHandler copy];
            // Deliver on the session's own delegate queue, where a real task's
            // completion would fire (the resolver may complete on any queue).
            NSOperationQueue *deliveryQueue = self.delegateQueue;
            NSURL *apiURL = url;

            void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
                ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
                ApolloSportsClipsResolveID(code, ^(NSDictionary *json) {
                    void (^deliver)(void) = ^{
                        if (json) {
                            NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                            NSHTTPURLResponse *ok = [[NSHTTPURLResponse alloc]
                                initWithURL:apiURL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Content-Type": @"application/json"}];
                            handler(body, ok, nil);
                        } else {
                            // Dead clip / scrape miss: report like a vanished
                            // Streamable video so Apollo shows its normal
                            // video-error state.
                            NSHTTPURLResponse *gone = [[NSHTTPURLResponse alloc]
                                initWithURL:apiURL statusCode:404 HTTPVersion:@"HTTP/1.1"
                                headerFields:@{@"Content-Type": @"application/json"}];
                            handler([NSData data], gone, nil);
                        }
                    };
                    if (deliveryQueue) {
                        [deliveryQueue addOperationWithBlock:deliver];
                    } else {
                        deliver();
                    }
                });
            };
            // Route the task to a fast-failing URL; the wrapper delivers the
            // synthetic payload (same pattern as the Imgur fabrication in
            // Tweak.xm).
            return %orig([NSURL URLWithString:@"http://127.0.0.1:1"], wrapped);
        }
    }
    return %orig;
}

%end

%ctor {
    ApolloLog(@"[SportsClips] ctor: hooks installed (enabled=%d)", (int)ApolloSportsClipsEnabled());
}
