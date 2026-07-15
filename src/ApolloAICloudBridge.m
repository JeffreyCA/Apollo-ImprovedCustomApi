//
//  ApolloAICloudBridge.m
//  See ApolloAICloudBridge.h for the surface/error contract. All internal state
//  is confined to a serial queue that doubles as the NSURLSession delegate
//  queue, so delegate callbacks and public entry points never race.
//

#import "ApolloAICloudBridge.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSString *const ApolloAICloudBridgeErrorDomain = @"ApolloAICloudBridge";

// Error codes shared with the FoundationModels bridge contract.
static const NSInteger kCloudErrorUnknown = 5;
static const NSInteger kCloudErrorCancelled = 6;
static const NSInteger kCloudErrorContextWindow = 8;
static const NSInteger kCloudErrorAuth = 11;
static const NSInteger kCloudErrorService = 12;

#pragma mark - Provider configuration

NSString *ApolloAICloudDefaultModelForProvider(NSString *provider) {
    if ([provider isEqualToString:@"openrouter"]) return @"meta-llama/llama-3.3-70b-instruct:free";
    if ([provider isEqualToString:@"gemini"]) return @"gemini-2.5-flash";
    return nil; // custom: no sensible default, the user must name a model
}

static NSString *CloudAPIKey(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) return sOpenRouterAPIKey;
    if ([sAISummaryProvider isEqualToString:@"gemini"]) return sGeminiAPIKey;
    if ([sAISummaryProvider isEqualToString:@"custom"]) return sCustomAIAPIKey;
    return nil;
}

NSString *ApolloAICloudEffectiveModel(void) {
    NSString *stored = nil;
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) stored = sOpenRouterAIModel;
    else if ([sAISummaryProvider isEqualToString:@"gemini"]) stored = sGeminiAIModel;
    else if ([sAISummaryProvider isEqualToString:@"custom"]) stored = sCustomAIModel;
    return stored.length > 0 ? stored : ApolloAICloudDefaultModelForProvider(sAISummaryProvider);
}

// Chat-completions endpoint for the active provider, nil when unconfigurable.
static NSURL *CloudEndpointURL(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) {
        return [NSURL URLWithString:@"https://openrouter.ai/api/v1/chat/completions"];
    }
    if ([sAISummaryProvider isEqualToString:@"gemini"]) {
        // Gemini's OpenAI-compatibility endpoint (Bearer auth with the Gemini API key).
        return [NSURL URLWithString:@"https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"];
    }
    if ([sAISummaryProvider isEqualToString:@"custom"]) {
        NSString *base = [sCustomAIBaseURL stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (base.length == 0) return nil;
        while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
        // Accept both a bare base URL (https://api.example.com/v1) and a full
        // chat-completions path pasted verbatim.
        if (![base hasSuffix:@"/chat/completions"]) {
            base = [base stringByAppendingString:@"/chat/completions"];
        }
        return [NSURL URLWithString:base];
    }
    return nil;
}

#pragma mark - Per-request state

@interface ApolloAICloudRequest : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLRequest *request;         // kept for the single internal retry
@property (nonatomic, strong) NSMutableString *accumulated;  // streamed content so far
@property (nonatomic, strong) NSMutableData *lineBuffer;     // partial SSE line carry-over
@property (nonatomic, strong) NSMutableData *errorBody;      // raw body when HTTP status != 200
@property (nonatomic, assign) NSInteger httpStatus;
@property (nonatomic, copy) NSString *retryAfterHeader;
@property (nonatomic, assign) BOOL retried;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, copy) void (^onPartial)(NSString *partial);
@property (nonatomic, copy) void (^onComplete)(NSString *final, NSError *error);
@end

@implementation ApolloAICloudRequest
@end

#pragma mark - Bridge

@interface ApolloAICloudBridge () <NSURLSessionDataDelegate>
@end

@implementation ApolloAICloudBridge {
    NSURLSession *_session;
    dispatch_queue_t _stateQueue; // serial; also the session delegate queue's underlying queue
    NSMutableDictionary<NSString *, ApolloAICloudRequest *> *_requestsByIdentifier;
    NSMutableDictionary<NSNumber *, ApolloAICloudRequest *> *_requestsByTask;
}

+ (instancetype)shared {
    static ApolloAICloudBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _stateQueue = dispatch_queue_create("com.apollo-reborn.aicloud", DISPATCH_QUEUE_SERIAL);
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.underlyingQueue = _stateQueue;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        // For a streaming response the request timeout is the inter-chunk idle
        // timeout — 30s matches the summary module's own generation watchdog.
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 90.0;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
        _requestsByIdentifier = [NSMutableDictionary dictionary];
        _requestsByTask = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark Availability

- (NSInteger)availabilityStatus {
    // 4 = unconfigured: reuses the FM "framework absent" status so the summary
    // module's existing silent-skip path covers "cloud selected but no key yet".
    if (CloudAPIKey().length == 0) return 4;
    if (!CloudEndpointURL()) return 4;                  // custom without a base URL
    if (ApolloAICloudEffectiveModel().length == 0) return 4; // custom without a model
    return 0;
}

- (BOOL)isModelAvailable {
    return [self availabilityStatus] == 0;
}

#pragma mark No-op session prewarm (nothing to prewarm over HTTP)

- (void)prepareSession:(NSString *)identifier instructions:(NSString *)instructions {}
- (void)discardPreparedSession:(NSString *)identifier {}

#pragma mark Cancellation

- (void)cancelRequest:(NSString *)identifier {
    if (identifier.length == 0) return;
    dispatch_async(_stateQueue, ^{
        ApolloAICloudRequest *state = self->_requestsByIdentifier[identifier];
        if (!state) return;
        [state.task cancel];
        // Finish immediately rather than waiting for didCompleteWithError —
        // this also covers the internal-retry wait window, where the previous
        // task has already completed and cancelling it would be a no-op (the
        // pending retry checks state.finished and won't fire). The finished
        // flag makes the later delegate callback a harmless no-op.
        [self finishState:state final:nil errorCode:kCloudErrorCancelled message:@"cancelled"];
    });
}

#pragma mark Summarize

- (void)summarize:(NSString *)text
       identifier:(NSString *)identifier
     instructions:(NSString *)instructions
maximumResponseTokens:(NSInteger)maximumResponseTokens
        onPartial:(void (^)(NSString *partial))onPartial
       onComplete:(void (^)(NSString *final, NSError *error))onComplete {
    if (!onComplete) return;

    NSString *apiKey = CloudAPIKey();
    NSURL *endpoint = CloudEndpointURL();
    NSString *model = ApolloAICloudEffectiveModel();
    if (apiKey.length == 0 || !endpoint || model.length == 0) {
        // Normally unreachable (availabilityStatus gates first), but guard anyway.
        NSError *error = [NSError errorWithDomain:ApolloAICloudBridgeErrorDomain
                                             code:kCloudErrorService
                                         userInfo:@{NSLocalizedDescriptionKey: @"Cloud AI provider is not configured"}];
        dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, error); });
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    if (instructions.length > 0) {
        [messages addObject:@{@"role": @"system", @"content": instructions}];
    }
    [messages addObject:@{@"role": @"user", @"content": text ?: @""}];
    NSDictionary *payload = @{
        @"model": model,
        @"messages": messages,
        @"max_tokens": @(maximumResponseTokens),
        @"stream": @YES,
    };
    NSError *jsonError;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!body) {
        NSError *error = [NSError errorWithDomain:ApolloAICloudBridgeErrorDomain
                                             code:kCloudErrorUnknown
                                         userInfo:@{NSLocalizedDescriptionKey: jsonError.localizedDescription ?: @"request encoding failed"}];
        dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, error); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) {
        // OpenRouter's recommended attribution headers (used for their rankings).
        [request setValue:@"https://github.com/Apollo-Reborn/Apollo-Reborn" forHTTPHeaderField:@"HTTP-Referer"];
        [request setValue:@"Apollo Reborn" forHTTPHeaderField:@"X-Title"];
    }

    dispatch_async(_stateQueue, ^{
        // A newer request for the same identifier supersedes the old one
        // (mirrors the FoundationModels bridge, which cancels the prior task).
        ApolloAICloudRequest *previous = self->_requestsByIdentifier[identifier];
        if (previous) [previous.task cancel];

        ApolloAICloudRequest *state = [[ApolloAICloudRequest alloc] init];
        state.identifier = identifier;
        state.request = request;
        state.accumulated = [NSMutableString string];
        state.lineBuffer = [NSMutableData data];
        state.onPartial = onPartial;
        state.onComplete = onComplete;
        [self startTaskForState:state];
        ApolloLog(@"[AICloud] request %@ started (provider=%@ model=%@)", identifier, sAISummaryProvider, model);
    });
}

// _stateQueue only.
- (void)startTaskForState:(ApolloAICloudRequest *)state {
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:state.request];
    state.task = task;
    state.httpStatus = 0;
    state.retryAfterHeader = nil;
    state.errorBody = nil;
    [state.lineBuffer setLength:0];
    _requestsByIdentifier[state.identifier] = state;
    _requestsByTask[@(task.taskIdentifier)] = state;
    [task resume];
}

#pragma mark Completion plumbing (_stateQueue only)

- (void)finishState:(ApolloAICloudRequest *)state final:(NSString *)final errorCode:(NSInteger)code message:(NSString *)message {
    if (!state || state.finished) return;
    state.finished = YES;
    [_requestsByTask removeObjectForKey:@(state.task.taskIdentifier)];
    if (_requestsByIdentifier[state.identifier] == state) {
        [_requestsByIdentifier removeObjectForKey:state.identifier];
    }
    void (^onComplete)(NSString *, NSError *) = state.onComplete;
    if (final) {
        dispatch_async(dispatch_get_main_queue(), ^{ onComplete(final, nil); });
        return;
    }
    NSError *error = [NSError errorWithDomain:ApolloAICloudBridgeErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message ?: @"unknown error"}];
    if (code != kCloudErrorCancelled) {
        ApolloLog(@"[AICloud] request %@ failed (code=%ld): %@", state.identifier, (long)code, message);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, error); });
}

// One internal retry for transient HTTP statuses, honoring Retry-After up to 5s.
- (void)retryState:(ApolloAICloudRequest *)state {
    state.retried = YES;
    NSTimeInterval delay = 1.0;
    double retryAfter = state.retryAfterHeader.doubleValue;
    if (retryAfter > 0) delay = MIN(retryAfter, 5.0);
    ApolloLog(@"[AICloud] request %@ got HTTP %ld, retrying once in %.1fs", state.identifier, (long)state.httpStatus, delay);
    // Detach from the finished task; the identifier keeps pointing at us so a
    // cancelRequest: during the wait still cancels (the task is already done,
    // so mark finished directly).
    [_requestsByTask removeObjectForKey:@(state.task.taskIdentifier)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _stateQueue, ^{
        if (state.finished) return;
        if (self->_requestsByIdentifier[state.identifier] != state) return; // superseded meanwhile
        [self startTaskForState:state];
    });
}

#pragma mark Error mapping

// Extracts a human-readable message from an OpenAI-style error body:
// {"error": {"message": "...", ...}} (string and nested-dict variants).
static NSString *CloudErrorMessageFromBody(NSData *body) {
    if (body.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        return raw.length > 0 && raw.length <= 300 ? raw : nil;
    }
    id error = ((NSDictionary *)json)[@"error"];
    if ([error isKindOfClass:[NSString class]]) return error;
    if ([error isKindOfClass:[NSDictionary class]]) {
        id message = ((NSDictionary *)error)[@"message"];
        if ([message isKindOfClass:[NSString class]]) return message;
    }
    return nil;
}

static BOOL CloudMessageSuggestsContextOverflow(NSString *message) {
    if (message.length == 0) return NO;
    for (NSString *needle in @[@"context", @"token", @"length", @"too long", @"maximum"]) {
        if ([message localizedCaseInsensitiveContainsString:needle]) return YES;
    }
    return NO;
}

- (void)handleHTTPFailureForState:(ApolloAICloudRequest *)state {
    NSInteger status = state.httpStatus;
    NSString *message = CloudErrorMessageFromBody(state.errorBody)
        ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];

    if ((status == 429 || status == 500 || status == 502 || status == 503) && !state.retried) {
        [self retryState:state];
        return;
    }
    NSInteger code;
    if (status == 401 || status == 402 || status == 403) {
        code = kCloudErrorAuth;
    } else if (status == 400 && CloudMessageSuggestsContextOverflow(message)) {
        code = kCloudErrorContextWindow;
    } else {
        code = kCloudErrorService;
    }
    [self finishState:state final:nil errorCode:code message:message];
}

#pragma mark SSE parsing (_stateQueue via the session delegate queue)

- (void)processSSELine:(NSString *)line forState:(ApolloAICloudRequest *)state {
    if (line.length == 0 || [line hasPrefix:@":"]) return; // keep-alive comment
    if (![line hasPrefix:@"data:"]) return;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if ([payload isEqualToString:@"[DONE]"]) {
        if (state.accumulated.length > 0) {
            [self finishState:state final:[state.accumulated copy] errorCode:0 message:nil];
        } else {
            [self finishState:state final:nil errorCode:kCloudErrorService message:@"empty response from model"];
        }
        return;
    }
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return; // tolerate malformed keep-alives
    NSDictionary *chunk = (NSDictionary *)json;

    // OpenRouter can surface an error object mid-stream.
    id chunkError = chunk[@"error"];
    if ([chunkError isKindOfClass:[NSDictionary class]] || [chunkError isKindOfClass:[NSString class]]) {
        NSString *message = [chunkError isKindOfClass:[NSString class]]
            ? chunkError : (((NSDictionary *)chunkError)[@"message"] ?: @"provider error");
        NSInteger providerCode = [chunkError isKindOfClass:[NSDictionary class]]
            ? [((NSDictionary *)chunkError)[@"code"] integerValue] : 0;
        BOOL authProblem = providerCode == 401 || providerCode == 402 || providerCode == 403;
        [self finishState:state final:nil
                errorCode:(authProblem ? kCloudErrorAuth : kCloudErrorService)
                  message:[message description]];
        return;
    }

    NSArray *choices = chunk[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) return; // usage/keep-alive chunk
    NSDictionary *delta = [choices[0] isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)choices[0])[@"delta"] : nil;
    id content = [delta isKindOfClass:[NSDictionary class]] ? delta[@"content"] : nil;
    if (![content isKindOfClass:[NSString class]] || [(NSString *)content length] == 0) return; // role-only chunk
    [state.accumulated appendString:content];

    if (state.onPartial) {
        NSString *cumulative = [state.accumulated copy]; // FM contract: partials are cumulative
        void (^onPartial)(NSString *) = state.onPartial;
        dispatch_async(dispatch_get_main_queue(), ^{ onPartial(cumulative); });
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    ApolloAICloudRequest *state = _requestsByTask[@(dataTask.taskIdentifier)];
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        state.httpStatus = http.statusCode;
        state.retryAfterHeader = http.allHeaderFields[@"Retry-After"];
        if (http.statusCode != 200) state.errorBody = [NSMutableData data];
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    ApolloAICloudRequest *state = _requestsByTask[@(dataTask.taskIdentifier)];
    if (!state || state.finished) return;

    if (state.httpStatus != 200) {
        [state.errorBody appendData:data]; // buffered whole for error extraction
        return;
    }

    [state.lineBuffer appendData:data];
    // Split off every complete line; a trailing partial line stays buffered.
    const char *bytes = state.lineBuffer.bytes;
    NSUInteger length = state.lineBuffer.length;
    NSUInteger lineStart = 0;
    for (NSUInteger i = 0; i < length && !state.finished; i++) {
        if (bytes[i] != '\n') continue;
        NSUInteger lineLength = i - lineStart;
        if (lineLength > 0 && bytes[i - 1] == '\r') lineLength--;
        NSString *line = [[NSString alloc] initWithBytes:bytes + lineStart
                                                  length:lineLength
                                                encoding:NSUTF8StringEncoding];
        if (line) [self processSSELine:line forState:state];
        lineStart = i + 1;
    }
    if (lineStart > 0) {
        [state.lineBuffer replaceBytesInRange:NSMakeRange(0, lineStart) withBytes:NULL length:0];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    ApolloAICloudRequest *state = _requestsByTask[@(task.taskIdentifier)];
    if (!state || state.finished) return;

    if (error) {
        if (error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain]) {
            [self finishState:state final:nil errorCode:kCloudErrorCancelled message:@"cancelled"];
        } else {
            // Timeouts, DNS, offline, TLS, ATS-blocked plain-http custom URLs…
            [self finishState:state final:nil errorCode:kCloudErrorService
                      message:error.localizedDescription ?: @"network error"];
        }
        return;
    }
    if (state.httpStatus != 200) {
        [self handleHTTPFailureForState:state];
        return;
    }
    // Clean close without an explicit [DONE]: content received counts as success.
    if (state.accumulated.length > 0) {
        [self finishState:state final:[state.accumulated copy] errorCode:0 message:nil];
    } else {
        [self finishState:state final:nil errorCode:kCloudErrorService message:@"empty response from model"];
    }
}

@end
