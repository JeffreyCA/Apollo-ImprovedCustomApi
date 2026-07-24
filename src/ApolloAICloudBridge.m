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
static const NSInteger kCloudErrorReasoningOnly = 13;

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
@property (nonatomic, copy) NSString *lastPartialVisible; // last partial actually delivered
@property (nonatomic, copy) NSString *finishReason;       // finish_reason from the final chunk, if any
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
        // timeout. It must outlast a whole thinking phase, not just a network
        // hiccup: Gemini streams NOTHING while a reasoning model thinks
        // (thoughts are excluded from its OpenAI-compat stream, but arrive
        // before any content), whereas OpenRouter keeps the stream warm with
        // keep-alive comments regardless.
        config.timeoutIntervalForRequest = 60.0;
        config.timeoutIntervalForResource = 180.0;
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
    // Reasoning/thinking tokens count against max_tokens on both OpenRouter and
    // Gemini, so the caller's ~80-110-token visible-summary budget starves any
    // thinking model: it burns the whole cap reasoning and the actual summary
    // arrives empty ("In 1") or truncated mid-thought. The prompt instructions
    // are what bound the visible length; max_tokens is only a runaway cap, so
    // give it generous headroom. Custom gets a smaller cap: local servers
    // (Ollama / llama.cpp / vLLM) reject prompt+max_tokens beyond the loaded
    // model's context window, and 2k stays inside even a 4k-context model.
    BOOL isCustom = [sAISummaryProvider isEqualToString:@"custom"];
    NSInteger tokenBudget = MAX(isCustom ? 2048 : 4096, maximumResponseTokens * 8);

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"model": model,
        @"messages": messages,
        @"max_tokens": @(tokenBudget),
        @"stream": @YES,
    }];
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) {
        // Keep reasoning out of the response entirely: some hosts (notably free
        // tiers) otherwise stream chain-of-thought as ordinary content deltas.
        // "exclude" is the one universally-supported reasoning control — it
        // never *enables* reasoning on hybrid models (unlike "effort", whose
        // presence implies enabled:true) and, unlike effort:"none", is not
        // rejected by mandatory-reasoning models.
        payload[@"reasoning"] = @{@"exclude": @YES};
    } else if ([sAISummaryProvider isEqualToString:@"gemini"]) {
        // Turn thinking off where Gemini permits it — only the 2.5 Flash family
        // does; 2.5 Pro and Gemini 3 reject "none" outright, so gate on the
        // model and let those think inside the enlarged max_tokens instead
        // (their thoughts stay out of the OpenAI-compat stream by default).
        NSString *normalizedModel = [model lowercaseString];
        if ([normalizedModel hasPrefix:@"models/"]) normalizedModel = [normalizedModel substringFromIndex:7];
        if ([normalizedModel hasPrefix:@"gemini-2.5-flash"]) {
            payload[@"reasoning_effort"] = @"none";
        }
    }
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

#pragma mark Reasoning-in-content stripping

// Reasoning models can leak chain-of-thought into message content instead of a
// separate reasoning field (free-tier OpenRouter hosts, local servers behind
// the custom provider). Two shapes exist in the wild: a tagged block
// (<think>…</think> — DeepSeek R1 family, Qwen, Nemotron), and reasoning that
// ends with a bare closing tag because the opening tag is baked into the
// model's chat template so it never appears in output. Content is accumulated
// raw; this derives what the user should actually see. Streaming-safe: an
// as-yet-unclosed tagged block (or a chunk boundary landing inside the tag
// literal, "<thi") is hidden until more of the stream arrives. The one
// unfixable-client-side shape — untagged reasoning with the closing tag still
// to come — can only show transiently in partials; the final text snaps to the
// post-tag answer, and the reasoning:{exclude:true} request parameter keeps
// OpenRouter from sending any of these shapes in the first place.
static NSString *CloudVisibleTextFromRaw(NSString *raw) {
    if (raw.length == 0) return raw;
    NSString *visible = raw;
    // Everything before the LAST closing tag is reasoning (this also disposes
    // of any properly-opened block preceding it).
    for (NSString *close in @[@"</think>", @"</thinking>"]) {
        NSRange r = [visible rangeOfString:close
                                   options:NSCaseInsensitiveSearch | NSBackwardsSearch];
        if (r.location != NSNotFound) visible = [visible substringFromIndex:NSMaxRange(r)];
    }
    // A block whose closing tag hasn't arrived (yet): hide from the opener on.
    for (NSString *open in @[@"<think>", @"<thinking>"]) {
        NSRange r = [visible rangeOfString:open options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) visible = [visible substringToIndex:r.location];
    }
    // A chunk boundary can land inside the tag literal itself: hide a trailing
    // "<", "<th", … that is a strict prefix of an opening tag.
    NSRange lastAngle = [visible rangeOfString:@"<" options:NSBackwardsSearch];
    if (lastAngle.location != NSNotFound) {
        NSString *tail = [[visible substringFromIndex:lastAngle.location] lowercaseString];
        if (tail.length < @"<thinking>".length &&
            ([@"<think>" hasPrefix:tail] || [@"<thinking>" hasPrefix:tail])) {
            visible = [visible substringToIndex:lastAngle.location];
        }
    }
    return [visible stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark SSE parsing (_stateQueue via the session delegate queue)

// _stateQueue only. The stream ended without an error: deliver the visible
// (reasoning-stripped) text, or a specific failure when nothing visible came.
- (void)finishStreamForState:(ApolloAICloudRequest *)state {
    NSString *visible = CloudVisibleTextFromRaw(state.accumulated);
    if (visible.length > 0) {
        [self finishState:state final:visible errorCode:0 message:nil];
    } else if (state.accumulated.length > 0 || [state.finishReason isEqualToString:@"length"]) {
        // Either the content was all chain-of-thought, or the model hit the
        // max_tokens cap while still thinking (Gemini reports finish_reason
        // "length" with empty content in that case).
        [self finishState:state final:nil errorCode:kCloudErrorReasoningOnly
                  message:@"model spent the whole response reasoning"];
    } else {
        [self finishState:state final:nil errorCode:kCloudErrorService
                  message:@"empty response from model"];
    }
}

- (void)processSSELine:(NSString *)line forState:(ApolloAICloudRequest *)state {
    if (line.length == 0 || [line hasPrefix:@":"]) return; // keep-alive comment
    if (![line hasPrefix:@"data:"]) return;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if ([payload isEqualToString:@"[DONE]"]) {
        [self finishStreamForState:state];
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
    NSDictionary *choice = [choices[0] isKindOfClass:[NSDictionary class]] ? choices[0] : nil;
    id finishReason = choice[@"finish_reason"];
    if ([finishReason isKindOfClass:[NSString class]]) state.finishReason = finishReason;
    NSDictionary *delta = choice[@"delta"];
    id content = [delta isKindOfClass:[NSDictionary class]] ? delta[@"content"] : nil;
    // Note: delta.reasoning / delta.reasoning_details / delta.reasoning_content
    // are deliberately ignored — chain-of-thought is never user-visible.
    if (![content isKindOfClass:[NSString class]] || [(NSString *)content length] == 0) return; // role-only chunk
    [state.accumulated appendString:content];

    if (state.onPartial) {
        // FM contract: partials are cumulative. Deliver the reasoning-stripped
        // view, and only when it changed — while a <think> block streams, the
        // visible text sits unchanged (often empty) and there is nothing to say.
        NSString *visible = CloudVisibleTextFromRaw(state.accumulated);
        if (visible.length > 0 && ![visible isEqualToString:state.lastPartialVisible]) {
            state.lastPartialVisible = visible;
            void (^onPartial)(NSString *) = state.onPartial;
            dispatch_async(dispatch_get_main_queue(), ^{ onPartial(visible); });
        }
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
    // Clean close without an explicit [DONE]: same handling as [DONE].
    [self finishStreamForState:state];
}

@end
