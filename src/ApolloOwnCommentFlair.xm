// Restore the poster's own user flair on a comment they just submitted.
//
// THE BUG
// Post a comment and it appears instantly in the thread, but with no flair pill
// next to your username; every other commenter's flair renders fine, and a
// pull-to-refresh makes yours appear. Reported for both account modes.
//
// ROOT CAUSE (verified for keyless, inferred-then-confirmed-by-log for API key)
// Reddit's comment-create response does not carry author_flair_* for the thing
// it just created:
//   * Keyless: www.reddit.com/api/comment answers in the legacy
//     {parent, content:"<html>"} shape, which ApolloWebJSONSynthesizeModernThingData
//     (ApolloWebJSON.m) rebuilds into a modern comment dict. That synthesis writes
//     28 keys and no author_flair_* key at all — a hard, unconditional drop.
//   * API key: oauth.reddit.com/api/comment goes through the exact same parser as
//     a normal listing (RDKClient -objectsFromDataThingsListingResponse: ->
//     +[RDKObjectBuilder objectFromJSON:] -> +[MTLJSONAdapter modelOfClass:...]),
//     so Apollo cannot be losing the flair on the way in — the payload lacks it.
// Either way the resulting RDKComment has empty authorFlairRichtext AND empty
// authorFlairPlaintext, and the cell renders nothing.
//
// WHY THE CELL CAN'T BE FIXED AFTER THE FACT
// -[RDKComment authorFlair] is a COMPUTED getter (it never reads its own
// _authorFlair ivar, so -setAuthorFlair:/KVC on @"authorFlair" is a no-op for
// display): it returns authorFlairRichtext when non-empty, else wraps
// authorFlairPlaintext in a fresh RDKFlair, else nil. CommentCellNode's init
// reads it exactly once and, when it is nil/empty, never allocates a FlairNode
// at all — and FlairNode.flairs is a Swift `let` with no setter. So there is no
// node to populate later: the flair has to be on the model BEFORE the cell is
// built. That rules out any render-time repair and makes this a data-layer fix.
//
// THE FIX
// Keep a small per-(account, subreddit) record of the user's own flair and use
// it to backfill exactly the comment they just posted:
//   1. LEARN, free: every model RedditKit parses passes through the MTLJSONAdapter
//      funnel that ApolloFlairColors.xm already hooks. Any RDKComment/RDKLink
//      authored by the active account teaches us that account's flair for that
//      subreddit — including the authoritative negative "no flair here".
//   2. LEARN, authoritative: the flair editor's save path writes through, so the
//      very next comment is right even on a cold cache.
//   3. PREFETCH: opening a thread parses its comments, which tells us the
//      subreddit; if we have no record for it we resolve one in the background
//      (once per subreddit per session). The user then spends seconds typing,
//      which is what makes the record warm by the time they hit send.
//   4. BACKFILL: -[RDKClient submitComment:...] arms a short-lived record. When
//      the response parses into an RDKComment that is ours, in that subreddit,
//      and has no flair, we write the cached pieces into authorFlairRichtext.
//
// The arm is what keeps this narrow: we only ever touch a comment the user just
// submitted, never their comment history, and never anyone else's comments.

#import "ApolloOwnCommentFlair.h"
#import "ApolloUserFlair.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>

static NSString *const kApolloOwnFlairGroupSuite = @"group.com.christianselig.apollo";
static NSString *const kApolloOwnFlairDefaultsKey = @"ApolloOwnCommentFlairV1";

// A record older than this is still used optimistically (the user's flair rarely
// changes) but is refreshed in the background on next sight.
static const NSTimeInterval kApolloOwnFlairStaleAfter = 24 * 60 * 60;
// An armed submit must be consumed quickly; a slow post still lands well inside.
static const NSTimeInterval kApolloOwnFlairArmTTL = 30.0;
static const NSUInteger kApolloOwnFlairMaxEntries = 120;

// Set on a comment we backfilled, so the harvester never mistakes our own
// optimistic flair for evidence of what Reddit actually has.
static char kApolloOwnFlairSynthesizedKey;

#pragma mark - Active account identity (cheap)

// ApolloActiveAccountUsername() unarchives RedditAccounts2 on every call, which
// is far too heavy for a funnel that fires for every model in every listing.
// RDKClient holds the same identity in memory; memoize it briefly on top of that.
static NSString *ApolloOwnFlairActiveUsername(void) {
    static NSString *cached = nil;
    static NSTimeInterval cachedAt = 0;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    os_unfair_lock_lock(&lock);
    NSString *hit = (now - cachedAt < 5.0) ? cached : nil;
    os_unfair_lock_unlock(&lock);
    if (hit) return hit;

    NSString *username = nil;
    @try {
        Class clientClass = objc_getClass("RDKClient");
        if (clientClass && [clientClass respondsToSelector:@selector(sharedClient)]) {
            id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient));
            if ([client respondsToSelector:@selector(currentUser)]) {
                id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
                if ([user respondsToSelector:@selector(username)]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(user, @selector(username));
                    if ([name isKindOfClass:[NSString class]] && [name length] > 0) username = name;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    // Keyless accounts are signed in through the web session, which may resolve
    // before RDKClient's currentUser does.
    if (username.length == 0) username = ApolloActiveWebSessionUsername();

    os_unfair_lock_lock(&lock);
    cached = [username copy];
    cachedAt = now;
    os_unfair_lock_unlock(&lock);
    return username;
}

static BOOL ApolloOwnFlairIsActiveUser(NSString *author) {
    if (author.length == 0) return NO;
    NSString *me = ApolloOwnFlairActiveUsername();
    if (me.length == 0) return NO;
    return [author caseInsensitiveCompare:me] == NSOrderedSame;
}

#pragma mark - Record store

// Keyed "<username-lowercase>|<subreddit-lowercase>" so switching accounts can
// never show account A's flair on account B's comment. A record's `pieces` array
// being empty is a positive answer ("known: no flair here"), distinct from having
// no record at all ("unknown") — only the latter triggers a prefetch, and neither
// an empty nor a missing record will ever backfill anything.
static NSMutableDictionary<NSString *, NSDictionary *> *ApolloOwnFlairStore(void) {
    static NSMutableDictionary *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [NSMutableDictionary dictionary];
        NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloOwnFlairGroupSuite];
        id saved = [group objectForKey:kApolloOwnFlairDefaultsKey];
        if ([saved isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)saved enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
                if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSDictionary class]])
                    store[key] = value;
            }];
        }
        ApolloLog(@"[OwnFlair] Loaded %lu cached own-flair record(s)", (unsigned long)store.count);
    });
    return store;
}

static NSString *ApolloOwnFlairKey(NSString *username, NSString *subreddit) {
    if (username.length == 0 || subreddit.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", username.lowercaseString, subreddit.lowercaseString];
}

static void ApolloOwnFlairPersist(void) {
    NSDictionary *snapshot = nil;
    @synchronized (ApolloOwnFlairStore()) {
        NSMutableDictionary *store = ApolloOwnFlairStore();
        // Cheap LRU: when over budget, drop the oldest records.
        if (store.count > kApolloOwnFlairMaxEntries) {
            NSArray *byAge = [store.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                double ta = [store[a][@"updatedAt"] doubleValue], tb = [store[b][@"updatedAt"] doubleValue];
                return ta < tb ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
            }];
            for (NSUInteger i = 0; i + kApolloOwnFlairMaxEntries < byAge.count; i++) [store removeObjectForKey:byAge[i]];
        }
        snapshot = [store copy];
    }
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloOwnFlairGroupSuite];
    [group setObject:snapshot forKey:kApolloOwnFlairDefaultsKey];
}

// nil = unknown, @[] = known-and-empty, non-empty = the user's flair pieces as
// plain JSON-safe dicts.
static NSArray<NSDictionary *> *ApolloOwnFlairLookup(NSString *username, NSString *subreddit, BOOL *outStale) {
    NSString *key = ApolloOwnFlairKey(username, subreddit);
    if (!key) return nil;
    NSDictionary *record = nil;
    @synchronized (ApolloOwnFlairStore()) { record = ApolloOwnFlairStore()[key]; }
    if (![record isKindOfClass:[NSDictionary class]]) return nil;
    id pieces = record[@"pieces"];
    if (![pieces isKindOfClass:[NSArray class]]) return nil;
    if (outStale) {
        NSTimeInterval updatedAt = [record[@"updatedAt"] doubleValue];
        *outStale = ([NSDate timeIntervalSinceReferenceDate] - updatedAt) > kApolloOwnFlairStaleAfter;
    }
    return pieces;
}

static void ApolloOwnFlairStorePieces(NSString *username, NSString *subreddit, NSArray<NSDictionary *> *pieces) {
    NSString *key = ApolloOwnFlairKey(username, subreddit);
    if (!key) return;
    NSArray *safe = [pieces isKindOfClass:[NSArray class]] ? pieces : @[];

    BOOL changed = NO, refreshed = NO;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    @synchronized (ApolloOwnFlairStore()) {
        NSDictionary *existing = ApolloOwnFlairStore()[key];
        changed = !existing || ![existing[@"pieces"] isEqual:safe];
        // Re-confirming the same value must still refresh the timestamp, or a
        // stable flair would go permanently stale and re-prefetch every launch
        // forever. Only persist when it actually matters, though: scrolling
        // re-parses our own comments constantly and each persist is a defaults write.
        refreshed = !changed && (now - [existing[@"updatedAt"] doubleValue]) > 3600.0;
        if (!changed && !refreshed) return;
        ApolloOwnFlairStore()[key] = @{ @"pieces": safe, @"updatedAt": @(now) };
    }
    ApolloOwnFlairPersist();
    if (changed)
        ApolloLog(@"[OwnFlair] Recorded own flair for r/%@: %lu piece(s)", subreddit, (unsigned long)safe.count);
}

// Subreddits already prefetched this launch, so a resolved miss doesn't re-ask on
// every thread open. File-scope rather than function-static because invalidation
// has to be able to clear it — otherwise the re-resolve it exists to trigger
// would be permanently suppressed.
static NSMutableSet<NSString *> *ApolloOwnFlairPrefetchAttempted(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ApolloOwnFlairForget(NSString *username, NSString *subreddit) {
    NSString *key = ApolloOwnFlairKey(username, subreddit);
    if (!key) return;
    @synchronized (ApolloOwnFlairStore()) { [ApolloOwnFlairStore() removeObjectForKey:key]; }
    @synchronized (ApolloOwnFlairPrefetchAttempted()) { [ApolloOwnFlairPrefetchAttempted() removeObject:key]; }
    ApolloOwnFlairPersist();
    ApolloLog(@"[OwnFlair] Invalidated own-flair record for r/%@", subreddit);
}

#pragma mark - RDKFlair <-> plain dict

// RDKFlair is a Mantle model with four properties. We persist plain dicts rather
// than archived objects so the store stays inspectable and version-proof, and we
// always hand the model FRESH RDKFlair instances: ApolloFlairColors.xm hangs
// per-instance colour annotations off each RDKFlair, so sharing one instance
// between cells would smear that state.
static NSArray<NSDictionary *> *ApolloOwnFlairSerializePieces(NSArray *flairs) {
    if (![flairs isKindOfClass:[NSArray class]] || flairs.count == 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id flair in flairs) {
        NSMutableDictionary *piece = [NSMutableDictionary dictionary];
        for (NSString *prop in @[@"flairType", @"text", @"emojiLabel"]) {
            @try {
                id value = [flair valueForKey:prop];
                if ([value isKindOfClass:[NSString class]]) piece[prop] = value;
            } @catch (__unused NSException *e) {}
        }
        @try {
            id url = [flair valueForKey:@"imageURL"];
            if ([url isKindOfClass:[NSURL class]]) piece[@"imageURL"] = [(NSURL *)url absoluteString];
            else if ([url isKindOfClass:[NSString class]]) piece[@"imageURL"] = url;
        } @catch (__unused NSException *e) {}
        if (piece.count > 0) [out addObject:piece];
    }
    return out;
}

static NSArray *ApolloOwnFlairMaterializePieces(NSArray<NSDictionary *> *pieces) {
    if (![pieces isKindOfClass:[NSArray class]] || pieces.count == 0) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *piece in pieces) {
        if (![piece isKindOfClass:[NSDictionary class]]) continue;
        NSString *imageURL = [piece[@"imageURL"] isKindOfClass:[NSString class]] ? piece[@"imageURL"] : nil;
        NSString *text = [piece[@"text"] isKindOfClass:[NSString class]] ? piece[@"text"] : nil;
        if (imageURL.length == 0 && text.length == 0) continue;  // nothing to draw
        id flair = nil;
        if (imageURL.length > 0) {
            // Emoji run: text MUST stay nil or the native flair cell renders it as
            // a text run instead of loading the image (see ApolloUserFlair.xm).
            NSString *label = [piece[@"emojiLabel"] isKindOfClass:[NSString class]] ? piece[@"emojiLabel"] : @"";
            flair = ApolloUserFlairBuildEmojiPiece(label, imageURL);
        } else {
            flair = ApolloUserFlairBuildTextPiece(text);
        }
        if (flair) [out addObject:flair];
    }
    return out.count > 0 ? out : nil;
}

#pragma mark - Submit arm

// One entry per in-flight write. Matching on subreddit keeps concurrent posts to
// different subreddits from crossing over.
//
// A matched arm is NOT removed, it is marked: `patched` caps the backfill at one
// comment, while the arm itself stays alive for its full TTL so it keeps
// suppressing the "no flair here" negative. That matters because RedditKit runs a
// model through the Mantle funnel more than once, and because a write response is
// never evidence about the account's real flair.
@interface ApolloOwnFlairArm : NSObject
@property (nonatomic, copy) NSString *subreddit;   // nil = wildcard
@property (nonatomic, assign) NSTimeInterval armedAt;
@property (nonatomic, assign) BOOL patched;
@end
@implementation ApolloOwnFlairArm
@end

static NSMutableArray<ApolloOwnFlairArm *> *ApolloOwnFlairArms(void) {
    static NSMutableArray *arms = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ arms = [NSMutableArray array]; });
    return arms;
}

static void ApolloOwnFlairPruneArms_locked(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray<ApolloOwnFlairArm *> *arms = ApolloOwnFlairArms();
    for (NSInteger i = (NSInteger)arms.count - 1; i >= 0; i--)
        if (now - arms[(NSUInteger)i].armedAt > kApolloOwnFlairArmTTL) [arms removeObjectAtIndex:(NSUInteger)i];
}

static void ApolloOwnFlairArmSubmit(NSString *subreddit) {
    ApolloOwnFlairArm *arm = [ApolloOwnFlairArm new];
    arm.subreddit = subreddit;
    arm.armedAt = [NSDate timeIntervalSinceReferenceDate];
    @synchronized (ApolloOwnFlairArms()) {
        ApolloOwnFlairPruneArms_locked();
        [ApolloOwnFlairArms() addObject:arm];
    }
    ApolloLog(@"[OwnFlair] Armed submit for r/%@", subreddit ?: @"<unknown>");
}

// The live arm covering this subreddit, if any. Never removes it — see the note
// on ApolloOwnFlairArm.
//
// Prefers an arm that has not spent its backfill: two comments posted into the
// same subreddit within the TTL each append their own arm, and always returning
// the first (by then patched) one would starve the second comment's claim. A
// patched match is still returned when it is the only match — the caller relies
// on arm != nil to keep suppressing the "no flair here" negative for the arm's
// whole TTL, not just until its backfill is used.
static ApolloOwnFlairArm *ApolloOwnFlairMatchArm(NSString *subreddit) {
    @synchronized (ApolloOwnFlairArms()) {
        ApolloOwnFlairPruneArms_locked();
        ApolloOwnFlairArm *patchedMatch = nil;
        for (ApolloOwnFlairArm *arm in ApolloOwnFlairArms()) {
            NSString *armed = arm.subreddit;
            if (armed.length == 0 || (subreddit.length > 0 && [armed caseInsensitiveCompare:subreddit] == NSOrderedSame)) {
                if (!arm.patched) return arm;
                if (!patchedMatch) patchedMatch = arm;
            }
        }
        return patchedMatch;
    }
}

// Claims the single backfill this arm is allowed. Returns NO if already used.
static BOOL ApolloOwnFlairClaimArmPatch(ApolloOwnFlairArm *arm) {
    if (!arm) return NO;
    @synchronized (ApolloOwnFlairArms()) {
        if (arm.patched) return NO;
        arm.patched = YES;
        return YES;
    }
}

// submitComment:onLink: and submitComment:asReplyToComment: both tail-call
// submitComment:onThingWithFullName: on the same thread, so this flag stops the
// fullname variant from adding a second, subreddit-less wildcard arm on top of
// the precise one we already have.
static NSString *const kApolloOwnFlairTypedScopeKey = @"ApolloOwnFlairTypedSubmitScope";

static void ApolloOwnFlairBeginTypedScope(void) {
    [[NSThread currentThread] threadDictionary][kApolloOwnFlairTypedScopeKey] = @YES;
}
static void ApolloOwnFlairEndTypedScope(void) {
    [[[NSThread currentThread] threadDictionary] removeObjectForKey:kApolloOwnFlairTypedScopeKey];
}
static BOOL ApolloOwnFlairInTypedScope(void) {
    return [[[NSThread currentThread] threadDictionary][kApolloOwnFlairTypedScopeKey] boolValue];
}

#pragma mark - Prefetch

// Resolving the user's own flair for a subreddit they have never commented in.
// Both account modes use the SAME oauth endpoint; only the bearer differs — a
// keyless account's token_v2 cookie is itself a valid OAuth bearer, which the
// repo already relies on for /r/<sub>/api/user_flair_v2. ApolloWebJSONProbeURL
// keeps the Web JSON transport from rewriting our own request back to www.
static NSMutableSet<NSString *> *ApolloOwnFlairPrefetchesInFlight(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ApolloOwnFlairPrefetch(NSString *username, NSString *subreddit) {
    NSString *key = ApolloOwnFlairKey(username, subreddit);
    if (!key) return;
    @synchronized (ApolloOwnFlairPrefetchesInFlight()) {
        if ([ApolloOwnFlairPrefetchesInFlight() containsObject:key]) return;
        [ApolloOwnFlairPrefetchesInFlight() addObject:key];
    }

    void (^done)(void) = ^{
        @synchronized (ApolloOwnFlairPrefetchesInFlight()) { [ApolloOwnFlairPrefetchesInFlight() removeObject:key]; }
    };

    // Everything below runs off the caller's thread. The thread-open hooks call us
    // from the main thread, and resolving a keyless bearer can MINT a fresh token_v2
    // — a synchronous, semaphore-gated HTML load documented as background-only that
    // blocks for up to 12s. Nothing here is needed before %orig returns.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL keyless = ApolloWebJSONHasUsableSession();
        NSString *bearer = keyless ? ApolloWebJSONKeylessOAuthBearer(username) : sLatestRedditBearerToken;
        if (bearer.length == 0) {
            ApolloLog(@"[OwnFlair] Prefetch for r/%@ skipped: no usable bearer", subreddit);
            done();
            return;
        }

        NSString *encoded = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/flairselector?raw_json=1", encoded]];
        if (!url) { done(); return; }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ApolloWebJSONProbeURL(url)];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [[NSString stringWithFormat:@"name=%@", username] dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
        request.timeoutInterval = 15.0;

        ApolloLog(@"[OwnFlair] Prefetching own flair for r/%@ (%@ bearer)", subreddit,
                  keyless ? @"keyless token_v2" : @"OAuth");

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) {
            ApolloLog(@"[OwnFlair] Prefetch for r/%@ failed: %@", subreddit, error.localizedDescription ?: @"empty response");
            done();
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![json isKindOfClass:[NSDictionary class]]) { done(); return; }
        id current = json[@"current"];
        if (![current isKindOfClass:[NSDictionary class]]) { done(); return; }

        id text = current[@"flair_text"];
        NSString *flairText = [text isKindOfClass:[NSString class]] ? text : nil;
        if (flairText.length == 0) {
            // Authoritative: this account has no flair in this subreddit.
            ApolloOwnFlairStorePieces(username, subreddit, @[]);
            done();
            return;
        }

        // Warm the subreddit's emoji catalogue first so ":token:" runs in the
        // flair text resolve to image pieces rather than literal text.
        ApolloUserFlairEnsureEmojisForSubreddit(subreddit, ^{
            NSArray *pieces = ApolloUserFlairBuildPiecesForText(flairText, subreddit);
            ApolloOwnFlairStorePieces(username, subreddit, ApolloOwnFlairSerializePieces(pieces));
            done();
        });
        }] resume];
    });
}

// Prefetching is deliberately tied to OPENING A THREAD, not to parsing a comment.
// Comments are deserialized in bulk in places the user is not about to reply from
// — the inbox alone parses comments from a dozen subreddits at launch — and
// prefetching on each would fire a burst of pointless requests. RDKClient's
// thread-open calls are the precise signal; the identifier-based variants don't
// carry a subreddit, so they raise a short-lived flag that the first comment
// parsed afterwards consumes.
// Deliberately global rather than thread-local: the request is issued on the main
// thread but its response parses on a network thread, so a thread dictionary
// would never carry the flag across.
static NSTimeInterval sApolloOwnFlairThreadOpenAt = 0;
static os_unfair_lock sApolloOwnFlairThreadOpenLock = OS_UNFAIR_LOCK_INIT;

static void ApolloOwnFlairMarkThreadOpening(void) {
    os_unfair_lock_lock(&sApolloOwnFlairThreadOpenLock);
    sApolloOwnFlairThreadOpenAt = [NSDate timeIntervalSinceReferenceDate];
    os_unfair_lock_unlock(&sApolloOwnFlairThreadOpenLock);
}

// Consumes the flag, so one thread open prefetches at most one subreddit.
static BOOL ApolloOwnFlairConsumeThreadOpening(void) {
    os_unfair_lock_lock(&sApolloOwnFlairThreadOpenLock);
    NSTimeInterval markedAt = sApolloOwnFlairThreadOpenAt;
    sApolloOwnFlairThreadOpenAt = 0;
    os_unfair_lock_unlock(&sApolloOwnFlairThreadOpenLock);
    // An unconsumed flag must not arm a prefetch for an unrelated subreddit later.
    return markedAt > 0 && ([NSDate timeIntervalSinceReferenceDate] - markedAt) < 20.0;
}

// Only ever one prefetch per subreddit per launch — a miss that resolves to
// "no flair" must not re-ask on every thread open.
static void ApolloOwnFlairMaybePrefetch(NSString *username, NSString *subreddit) {
    NSString *key = ApolloOwnFlairKey(username, subreddit);
    if (!key) return;

    BOOL stale = NO;
    NSArray *known = ApolloOwnFlairLookup(username, subreddit, &stale);
    if (known && !stale) return;

    @synchronized (ApolloOwnFlairPrefetchAttempted()) {
        if ([ApolloOwnFlairPrefetchAttempted() containsObject:key]) return;
        [ApolloOwnFlairPrefetchAttempted() addObject:key];
    }
    ApolloOwnFlairPrefetch(username, subreddit);
}

#pragma mark - Harvest + backfill

static NSString *ApolloOwnFlairStringProperty(id model, SEL selector) {
    if (![model respondsToSelector:selector]) return nil;
    id value = nil;
    @try { value = ((id (*)(id, SEL))objc_msgSend)(model, selector); }
    @catch (__unused NSException *e) { return nil; }
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// A comment the user just wrote is seconds old. Reddit stamps created/created_utc
// at creation on both paths (the keyless synthesis in ApolloWebJSON.m uses "now"),
// so this cheaply separates the write's own result from any older comment of ours
// that happens to parse during the arm window.
static BOOL ApolloOwnFlairIsRecent(id model) {
    if (![model respondsToSelector:@selector(createdUTC)]) return NO;
    id created = nil;
    @try { created = ((id (*)(id, SEL))objc_msgSend)(model, @selector(createdUTC)); }
    @catch (__unused NSException *e) { return NO; }
    if (![created isKindOfClass:[NSDate class]]) return NO;
    NSTimeInterval age = -[(NSDate *)created timeIntervalSinceNow];
    return age >= -60.0 && age < kApolloOwnFlairArmTTL;   // tolerate mild clock skew
}

static NSArray *ApolloOwnFlairArrayProperty(id model, SEL selector) {
    if (![model respondsToSelector:selector]) return nil;
    id value = nil;
    @try { value = ((id (*)(id, SEL))objc_msgSend)(model, selector); }
    @catch (__unused NSException *e) { return nil; }
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

void ApolloOwnCommentFlairInspectModel(id model) {
    if (!model) return;

    static Class commentClass = Nil, linkClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        commentClass = objc_getClass("RDKComment");
        linkClass = objc_getClass("RDKLink");
    });

    BOOL isComment = commentClass && [model isKindOfClass:commentClass];
    BOOL isLink = !isComment && linkClass && [model isKindOfClass:linkClass];
    if (!isComment && !isLink) return;

    NSString *subreddit = ApolloOwnFlairStringProperty(model, @selector(subreddit));
    if (subreddit.length == 0) return;

    // The first comment parsed after a thread-open call tells us which subreddit
    // the user is now reading — and may reply in. At most one request per
    // subreddit per launch.
    NSString *username = ApolloOwnFlairActiveUsername();
    if (isComment && username.length > 0 && ApolloOwnFlairConsumeThreadOpening())
        ApolloOwnFlairMaybePrefetch(username, subreddit);

    NSString *author = ApolloOwnFlairStringProperty(model, @selector(author));
    if (!ApolloOwnFlairIsActiveUser(author)) return;

    NSArray *richtext = ApolloOwnFlairArrayProperty(model, @selector(authorFlairRichtext));
    NSString *plaintext = ApolloOwnFlairStringProperty(model, @selector(authorFlairPlaintext));
    BOOL hasFlair = (richtext.count > 0) || (plaintext.length > 0);

    if (hasFlair) {
        // Never learn from a flair we ourselves invented.
        if (objc_getAssociatedObject(model, &kApolloOwnFlairSynthesizedKey)) return;
        if (richtext.count > 0) {
            NSArray<NSDictionary *> *pieces = ApolloOwnFlairSerializePieces(richtext);
            if (pieces.count > 0) ApolloOwnFlairStorePieces(username, subreddit, pieces);
            return;
        }
        // Plaintext-only: ":token:" runs need the subreddit's emoji catalogue to
        // become image pieces. Warming it first keeps a cold cache from persisting
        // literal ":token:" text that would later be painted onto a real comment.
        ApolloUserFlairEnsureEmojisForSubreddit(subreddit, ^{
            NSArray<NSDictionary *> *pieces =
                ApolloOwnFlairSerializePieces(ApolloUserFlairBuildPiecesForText(plaintext, subreddit));
            if (pieces.count > 0) ApolloOwnFlairStorePieces(username, subreddit, pieces);
        });
        return;
    }

    // No flair on one of our own things. Two very different reasons:
    //  * it came from a listing  -> authoritative "we have no flair here"
    //  * it is the comment we just posted -> the payload simply omits flair, and
    //    treating that as a negative would wipe the record we are about to use.
    // The arm tells them apart.
    ApolloOwnFlairArm *arm = isComment ? ApolloOwnFlairMatchArm(subreddit) : nil;
    if (!arm) {
        if (username.length > 0) ApolloOwnFlairStorePieces(username, subreddit, @[]);
        return;
    }

    // An arm says "a write to this subreddit is in flight", not "this exact model
    // is its result". Without a recency check, one of the user's OLD flairless
    // comments parsed during the window could claim the backfill. A comment that
    // was genuinely just written is seconds old.
    if (!ApolloOwnFlairIsRecent(model)) return;

    if (!ApolloOwnFlairClaimArmPatch(arm)) return;   // this write already backfilled

    BOOL stale = NO;
    NSArray<NSDictionary *> *cached = ApolloOwnFlairLookup(username, subreddit, &stale);
    if (cached.count == 0) {
        // Unknown, or known to be flairless here. Leave the comment blank — that
        // is today's behaviour, and guessing would be worse than a blank pill.
        ApolloLog(@"[OwnFlair] Fresh comment in r/%@ has no cached flair to restore — leaving blank", subreddit);
        return;
    }

    NSArray *pieces = ApolloOwnFlairMaterializePieces(cached);
    if (pieces.count == 0) return;
    if (![model respondsToSelector:@selector(setAuthorFlairRichtext:)]) return;

    // authorFlairRichtext, never authorFlair: -[RDKComment authorFlair] is a
    // computed getter that ignores its own ivar, so setAuthorFlair: renders nothing.
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(model, @selector(setAuthorFlairRichtext:), pieces);
    } @catch (__unused NSException *e) { return; }

    objc_setAssociatedObject(model, &kApolloOwnFlairSynthesizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[OwnFlair] Backfilled own flair on just-posted comment in r/%@ (%lu piece(s))",
              subreddit, (unsigned long)pieces.count);
}

#pragma mark - Write-through from the flair editor

void ApolloOwnCommentFlairRecordSetFlair(NSString *subreddit, NSString *text) {
    NSString *username = ApolloOwnFlairActiveUsername();
    if (username.length == 0 || subreddit.length == 0) return;
    if (text.length == 0) {
        ApolloOwnFlairStorePieces(username, subreddit, @[]);
        return;
    }
    ApolloUserFlairEnsureEmojisForSubreddit(subreddit, ^{
        NSArray *pieces = ApolloUserFlairBuildPiecesForText(text, subreddit);
        ApolloOwnFlairStorePieces(username, subreddit, ApolloOwnFlairSerializePieces(pieces));
    });
}

void ApolloOwnCommentFlairRecordShowFlair(NSString *subreddit, BOOL show) {
    NSString *username = ApolloOwnFlairActiveUsername();
    if (username.length == 0 || subreddit.length == 0) return;
    if (show) ApolloOwnFlairForget(username, subreddit);       // re-resolve the real value
    else ApolloOwnFlairStorePieces(username, subreddit, @[]);  // hidden flair renders as none
}

#pragma mark - Hooks

// Arm around the submit so the backfill can only ever touch the comment the user
// just posted. The response parses inside the completion, well within the arm TTL.
%hook RDKClient

- (id)submitComment:(id)comment onLink:(id)link completion:(id)completion {
    ApolloOwnFlairArmSubmit(ApolloOwnFlairStringProperty(link, @selector(subreddit)));
    ApolloOwnFlairBeginTypedScope();
    id result = %orig;
    ApolloOwnFlairEndTypedScope();
    return result;
}

- (id)submitComment:(id)comment asReplyToComment:(id)parent completion:(id)completion {
    ApolloOwnFlairArmSubmit(ApolloOwnFlairStringProperty(parent, @selector(subreddit)));
    ApolloOwnFlairBeginTypedScope();
    id result = %orig;
    ApolloOwnFlairEndTypedScope();
    return result;
}

- (id)submitComment:(id)comment onThingWithFullName:(id)fullName completion:(id)completion {
    // Only when reached directly: the two typed entry points above already armed
    // with a real subreddit and tail-call through here on the same thread.
    if (!ApolloOwnFlairInTypedScope()) ApolloOwnFlairArmSubmit(nil);
    return %orig;
}

// Editing has the same flair-less response shape as posting, so it needs the same
// arm — otherwise the edited comment comes back with no flair, the harvester reads
// that as "this account has no flair here", and it wipes the very record the fix
// depends on. The arm only suppresses that false negative here: an edited comment
// keeps its original createdUTC, so the recency gate declines to backfill it. That
// is deliberate — relaxing recency to cover edits would reopen the hole where an
// old flairless comment of ours claims the arm.
- (id)editComment:(id)comment newText:(id)text completion:(id)completion {
    ApolloOwnFlairArmSubmit(ApolloOwnFlairStringProperty(comment, @selector(subreddit)));
    return %orig;
}

// Opening a thread is the cue to make sure we know the user's flair there before
// they start typing a reply. The link-typed variant hands us the subreddit
// outright; the identifier variants don't, so they defer to the first comment
// parsed from the response.

- (id)commentsForLink:(id)link completion:(id)completion {
    NSString *subreddit = ApolloOwnFlairStringProperty(link, @selector(subreddit));
    NSString *username = ApolloOwnFlairActiveUsername();
    if (subreddit.length > 0 && username.length > 0) ApolloOwnFlairMaybePrefetch(username, subreddit);
    else ApolloOwnFlairMarkThreadOpening();
    return %orig;
}

- (id)commentsForLinkWithIdentifier:(id)identifier completion:(id)completion {
    ApolloOwnFlairMarkThreadOpening();
    return %orig;
}

- (id)commentsForLinkWithIdentifier:(id)identifier sort:(long long)sort limit:(long long)limit completion:(id)completion {
    ApolloOwnFlairMarkThreadOpening();
    return %orig;
}

- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier completion:(id)completion {
    ApolloOwnFlairMarkThreadOpening();
    return %orig;
}

- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier commentSort:(long long)sort pagination:(id)pagination completion:(id)completion {
    ApolloOwnFlairMarkThreadOpening();
    return %orig;
}

%end
