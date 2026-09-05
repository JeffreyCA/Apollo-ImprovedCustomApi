// Legacy-inbox chat mirror -> modern Chat room resolver. See the header for the
// data model. Data flow:
//
//   inbox row tap (ApolloChatsFilter) -> Resolve(subject, partner, timestamp)
//     -> directory fresh? else: bearer (ApolloChatUnreadPoller) -> sequenced
//        Matrix /sync pages -> merged room map + m.direct map
//     -> match (titled room by name / direct room by partner id)
//     -> "/chat/room/<id>" or nil (caller falls back to the legacy thread)
//
// Everything mutable lives on the main queue except the username -> fullname
// side table, which the JSON parser feeds from background threads.
#import "ApolloChatRoomDirectory.h"
#import "ApolloChatUnreadPoller.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloWebSessionStore.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>

// Reuse the directory this long before a tap refetches it; new rooms show up
// through the miss path below well before that.
static const NSTimeInterval kRoomDirectoryFreshInterval = 5.0 * 60.0;
// A lookup that misses re-syncs once, unless the directory was fetched this
// recently (a genuinely unmatched mirror must not sync on every tap).
static const NSTimeInterval kRoomDirectoryMissRefetchInterval = 20.0;
// How long a tap waits for a resolution before the legacy thread opens instead.
static const NSTimeInterval kRoomDirectoryTapDeadline = 6.0;
static const NSTimeInterval kRoomDirectoryRequestTimeout = 15.0;
// Reddit answers an initial sync in sequenced pages of ~20 rooms (the
// `com.reddit.sequenced_sync` flag stays set even once they run dry). Follow
// `next_batch` until a page adds nothing, with a hard cap.
static const NSUInteger kRoomDirectoryMaxPages = 12;
// Full room state (name, members, com.reddit.chat.type), one message per room
// for recency, and the account's m.direct map. No presence or ephemeral noise.
static NSString *const kRoomDirectorySyncFilter =
    @"{\"room\":{\"timeline\":{\"limit\":1,\"types\":[\"m.room.message\"]},"
    @"\"state\":{\"lazy_load_members\":false},\"ephemeral\":{\"types\":[]},\"account_data\":{\"types\":[]}},"
    @"\"presence\":{\"types\":[]},\"account_data\":{\"types\":[\"m.direct\"]}}";
// Same Safari persona the modern mailbox web views present (a cookie-backed
// www.reddit.com JSON request looks like the session Reddit harvested).
static NSString *const kRoomDirectoryBrowserUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";

@interface ApolloChatRoomEntry : NSObject
@property (nonatomic, copy) NSString *roomId;
@property (nonatomic, copy) NSString *name;          // m.room.name (titled rooms)
@property (nonatomic, copy) NSString *chatType;      // com.reddit.chat.type.type
@property (nonatomic, strong) NSMutableSet<NSString *> *participants;   // "@t2_…:reddit.com"
@property (nonatomic, assign) BOOL joined;           // listed under rooms.join
@property (nonatomic, assign) BOOL invited;          // listed under rooms.invite (a pending request)
@property (nonatomic, assign) double lastMessageTs;  // origin_server_ts of the newest message, ms
@end

@implementation ApolloChatRoomEntry
- (instancetype)init {
    self = [super init];
    if (self) _participants = [NSMutableSet set];
    return self;
}
@end

NSString * const ApolloChatRequestsPath = @"/chat/requests";

// Main-queue state.
static NSString *sDirectoryUsername = nil;    // lowercased owner of the maps below
static NSDictionary<NSString *, ApolloChatRoomEntry *> *sDirectoryRooms = nil;
static NSDictionary<NSString *, NSArray<NSString *> *> *sDirectoryDirectRooms = nil;   // partner user id -> room ids
static NSTimeInterval sDirectoryFetchedAt = 0;
static BOOL sDirectoryInFlight = NO;
static NSMutableArray<void (^)(BOOL)> *sDirectoryWaiters = nil;
static NSURLSession *sDirectorySession = nil;

// Lowercased username -> "t2_…", fed by the message JSON parser (any thread).
static NSMutableDictionary<NSString *, NSString *> *sUserFullnames = nil;
static os_unfair_lock sUserFullnamesLock = OS_UNFAIR_LOCK_INIT;

#pragma mark - Small helpers

BOOL ApolloChatSubjectIsRoomMarker(NSString *subject) {
    if (![subject isKindOfClass:[NSString class]] || subject.length == 0) return NO;
    NSString *trimmed = [[subject stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (![trimmed hasPrefix:@"["] || ![trimmed hasSuffix:@" chat room]"]) return NO;
    // Exactly one bracketed token and nothing outside it: the first closing
    // bracket must be the subject's final character.
    return [trimmed rangeOfString:@"]"].location == trimmed.length - 1;
}

void ApolloChatRoomDirectoryNoteUserFullname(NSString *username, NSString *fullname) {
    if (![username isKindOfClass:[NSString class]] || ![fullname isKindOfClass:[NSString class]]) return;
    if (username.length == 0 || ![fullname hasPrefix:@"t2_"] || fullname.length <= 3) return;
    NSString *key = username.lowercaseString;
    os_unfair_lock_lock(&sUserFullnamesLock);
    if (!sUserFullnames) sUserFullnames = [NSMutableDictionary dictionary];
    sUserFullnames[key] = fullname;
    os_unfair_lock_unlock(&sUserFullnamesLock);
}

static NSString *ApolloChatRoomDirectoryKnownFullname(NSString *username) {
    if (username.length == 0) return nil;
    os_unfair_lock_lock(&sUserFullnamesLock);
    NSString *fullname = sUserFullnames[username.lowercaseString];
    os_unfair_lock_unlock(&sUserFullnamesLock);
    return fullname;
}

// Matrix user id for a Reddit account fullname.
static NSString *ApolloChatRoomDirectoryMatrixUserId(NSString *fullname) {
    if (fullname.length == 0) return nil;
    return [NSString stringWithFormat:@"@%@:reddit.com", fullname];
}

static NSString *ApolloChatRoomDirectoryActiveUsername(void) {
    return ApolloActiveWebSessionUsername().lowercaseString ?: @"";
}

static NSURLSession *ApolloChatRoomDirectorySession(void) {
    if (!sDirectorySession) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        config.HTTPCookieStorage = nil;
        sDirectorySession = [NSURLSession sessionWithConfiguration:config];
    }
    return sDirectorySession;
}

// Room ids are "!<opaque>:reddit.com". Only that shape is ever placed in a path.
static BOOL ApolloChatRoomDirectoryRoomIdIsSafe(NSString *roomId) {
    if (![roomId isKindOfClass:[NSString class]] || roomId.length < 4 || roomId.length > 256) return NO;
    if (![roomId hasPrefix:@"!"]) return NO;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"!:.-_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"];
    });
    return [roomId rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

#pragma mark - Sync pages -> directory

// Fold one sync page into the accumulating maps. Later pages of a sequenced
// sync re-list rooms with only their delta (a new message, a state change), so
// every field merges into the existing entry rather than replacing it.
static NSUInteger ApolloChatRoomDirectoryMergePage(NSDictionary *payload,
                                                   NSMutableDictionary<NSString *, ApolloChatRoomEntry *> *rooms,
                                                   NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *directRooms) {
    NSUInteger newRooms = 0;
    NSDictionary *sections = [payload[@"rooms"] isKindOfClass:[NSDictionary class]] ? payload[@"rooms"] : @{};
    for (NSString *section in @[@"join", @"invite"]) {
        NSDictionary *roomMap = [sections[section] isKindOfClass:[NSDictionary class]] ? sections[section] : @{};
        for (NSString *roomId in roomMap) {
            NSDictionary *room = [roomMap[roomId] isKindOfClass:[NSDictionary class]] ? roomMap[roomId] : @{};
            ApolloChatRoomEntry *entry = rooms[roomId];
            if (!entry) {
                if (!ApolloChatRoomDirectoryRoomIdIsSafe(roomId)) continue;
                entry = [ApolloChatRoomEntry new];
                entry.roomId = roomId;
                rooms[roomId] = entry;
                newRooms++;
            }
            if ([section isEqualToString:@"join"]) {
                entry.joined = YES;
                entry.invited = NO;
            } else if (!entry.joined) {
                entry.invited = YES;
            }
            NSMutableArray *events = [NSMutableArray array];
            for (NSString *bucket in @[@"state", @"invite_state", @"timeline"]) {
                NSDictionary *holder = [room[bucket] isKindOfClass:[NSDictionary class]] ? room[bucket] : nil;
                NSArray *list = [holder[@"events"] isKindOfClass:[NSArray class]] ? holder[@"events"] : nil;
                if (list) [events addObjectsFromArray:list];
            }
            for (NSDictionary *event in events) {
                if (![event isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
                NSDictionary *content = [event[@"content"] isKindOfClass:[NSDictionary class]] ? event[@"content"] : @{};
                if ([type isEqualToString:@"m.room.name"]) {
                    if ([content[@"name"] isKindOfClass:[NSString class]]) entry.name = content[@"name"];
                } else if ([type isEqualToString:@"com.reddit.chat.type"]) {
                    if ([content[@"type"] isKindOfClass:[NSString class]]) entry.chatType = content[@"type"];
                    if ([content[@"participants"] isKindOfClass:[NSArray class]]) {
                        for (id participant in content[@"participants"]) {
                            if ([participant isKindOfClass:[NSString class]]) [entry.participants addObject:participant];
                        }
                    }
                } else if ([type isEqualToString:@"m.room.member"]) {
                    NSString *membership = [content[@"membership"] isKindOfClass:[NSString class]] ? content[@"membership"] : @"";
                    NSString *userId = [event[@"state_key"] isKindOfClass:[NSString class]] ? event[@"state_key"] : nil;
                    if (userId.length && ([membership isEqualToString:@"join"] || [membership isEqualToString:@"invite"])) {
                        [entry.participants addObject:userId];
                    }
                } else if ([type isEqualToString:@"m.room.message"]) {
                    double ts = [event[@"origin_server_ts"] respondsToSelector:@selector(doubleValue)]
                        ? [event[@"origin_server_ts"] doubleValue] : 0;
                    if (ts > entry.lastMessageTs) entry.lastMessageTs = ts;
                }
            }
            // The summary's heroes name the other participants of an unnamed
            // room even when its member events were not part of this page.
            NSDictionary *summary = [room[@"summary"] isKindOfClass:[NSDictionary class]] ? room[@"summary"] : nil;
            if ([summary[@"m.heroes"] isKindOfClass:[NSArray class]]) {
                for (id hero in summary[@"m.heroes"]) {
                    if ([hero isKindOfClass:[NSString class]]) [entry.participants addObject:hero];
                }
            }
        }
    }
    // Account data only rides on the first page; a later page never clears it.
    NSDictionary *accountData = [payload[@"account_data"] isKindOfClass:[NSDictionary class]] ? payload[@"account_data"] : nil;
    NSArray *accountEvents = [accountData[@"events"] isKindOfClass:[NSArray class]] ? accountData[@"events"] : @[];
    for (NSDictionary *event in accountEvents) {
        if (![event isKindOfClass:[NSDictionary class]] || ![event[@"type"] isEqual:@"m.direct"]) continue;
        NSDictionary *content = [event[@"content"] isKindOfClass:[NSDictionary class]] ? event[@"content"] : @{};
        for (NSString *userId in content) {
            if (![userId isKindOfClass:[NSString class]] || ![content[userId] isKindOfClass:[NSArray class]]) continue;
            NSMutableArray *ids = directRooms[userId] ?: [NSMutableArray array];
            for (id roomId in content[userId]) {
                if ([roomId isKindOfClass:[NSString class]] && ApolloChatRoomDirectoryRoomIdIsSafe(roomId) &&
                    ![ids containsObject:roomId]) {
                    [ids addObject:roomId];
                }
            }
            directRooms[userId] = ids;
        }
    }
    return newRooms;
}

static void ApolloChatRoomDirectoryFinish(BOOL ready) {
    sDirectoryInFlight = NO;
    NSArray *waiters = [sDirectoryWaiters copy];
    sDirectoryWaiters = nil;
    for (void (^waiter)(BOOL) in waiters) waiter(ready);
}

static void ApolloChatRoomDirectoryFetchPage(NSString *username, NSString *bearer, NSString *since, NSUInteger page,
                                             NSMutableDictionary<NSString *, ApolloChatRoomEntry *> *rooms,
                                             NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *directRooms,
                                             NSDate *startedAt) {
    NSURLComponents *components = [NSURLComponents componentsWithString:
        [ApolloChatPollHomeserver() stringByAppendingString:@"/_matrix/client/v3/sync"]];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"timeout" value:@"0"],
        [NSURLQueryItem queryItemWithName:@"set_presence" value:@"offline"],
        [NSURLQueryItem queryItemWithName:@"filter" value:kRoomDirectorySyncFilter],
    ]];
    if (since.length > 0) [query addObject:[NSURLQueryItem queryItemWithName:@"since" value:since]];
    components.queryItems = query;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = kRoomDirectoryRequestTimeout;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[ApolloChatRoomDirectorySession() dataTaskWithRequest:request
                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSDictionary *payload = nil;
        if (!error && statusCode == 200 && data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) payload = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![ApolloChatRoomDirectoryActiveUsername() isEqualToString:username]) {
                ApolloLog(@"[ChatRooms] Account changed mid-sync; dropping the room directory fetch");
                ApolloChatRoomDirectoryFinish(NO);
                return;
            }
            if (!payload) {
                ApolloLog(@"[ChatRooms] Room directory sync page %lu failed (HTTP %ld, %@)",
                          (unsigned long)page, (long)statusCode,
                          error.localizedDescription ?: @"unparseable body");
                if (statusCode == 401 || statusCode == 403) ApolloChatPollNoteBearerRejected(bearer);
                ApolloChatRoomDirectoryFinish(NO);
                return;
            }
            NSUInteger added = ApolloChatRoomDirectoryMergePage(payload, rooms, directRooms);
            NSString *next = [payload[@"next_batch"] isKindOfClass:[NSString class]] ? payload[@"next_batch"] : nil;
            BOOL sequenced = [payload[@"com.reddit.sequenced_sync"] respondsToSelector:@selector(boolValue)]
                && [payload[@"com.reddit.sequenced_sync"] boolValue];
            if (sequenced && next.length > 0 && added > 0 && page + 1 < kRoomDirectoryMaxPages) {
                ApolloChatRoomDirectoryFetchPage(username, bearer, next, page + 1, rooms, directRooms, startedAt);
                return;
            }
            NSUInteger named = 0, direct = 0;
            for (ApolloChatRoomEntry *entry in rooms.allValues) {
                if (entry.name.length) named++;
                if ([entry.chatType isEqualToString:@"direct"]) direct++;
            }
            sDirectoryUsername = [username copy];
            sDirectoryRooms = [rooms copy];
            sDirectoryDirectRooms = [directRooms copy];
            sDirectoryFetchedAt = [NSDate date].timeIntervalSince1970;
            ApolloLog(@"[ChatRooms] Room directory for u/%@: %lu rooms (%lu titled, %lu direct, %lu direct partners) "
                      @"over %lu page(s) in %.2fs",
                      username, (unsigned long)rooms.count, (unsigned long)named, (unsigned long)direct,
                      (unsigned long)directRooms.count, (unsigned long)(page + 1), -[startedAt timeIntervalSinceNow]);
            ApolloChatRoomDirectoryFinish(YES);
        });
    }] resume];
}

// Make sure a directory for the active account exists (fetching one when it
// is missing, stale, for another account, or when `force` asks for a refresh)
// and report readiness on the main queue. Concurrent callers share one fetch.
static void ApolloChatRoomDirectoryEnsure(BOOL force, void (^completion)(BOOL ready)) {
    NSString *username = ApolloChatRoomDirectoryActiveUsername();
    if (!ApolloModernChatShouldOpen() || username.length == 0) {
        completion(NO);
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL fresh = sDirectoryRooms != nil && [sDirectoryUsername isEqualToString:username] &&
        now - sDirectoryFetchedAt < kRoomDirectoryFreshInterval;
    if (fresh && !force) {
        completion(YES);
        return;
    }
    if (!sDirectoryWaiters) sDirectoryWaiters = [NSMutableArray array];
    [sDirectoryWaiters addObject:[completion copy]];
    if (sDirectoryInFlight) return;
    sDirectoryInFlight = YES;
    ApolloChatPollObtainBearerForActiveAccount(^(NSString *bearer) {
        if (bearer.length == 0 || ![ApolloChatRoomDirectoryActiveUsername() isEqualToString:username]) {
            ApolloLog(@"[ChatRooms] No Matrix bearer available for u/%@; room directory unavailable", username);
            ApolloChatRoomDirectoryFinish(NO);
            return;
        }
        ApolloChatRoomDirectoryFetchPage(username, bearer, nil, 0, [NSMutableDictionary dictionary],
                                         [NSMutableDictionary dictionary], [NSDate date]);
    });
}

void ApolloChatRoomDirectoryPrefetch(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloChatRoomDirectoryEnsure(NO, ^(__unused BOOL ready) {});
    });
}

#pragma mark - Matching

static NSString *ApolloChatRoomDirectoryTrim(NSString *string) {
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// Rank candidate rooms: a joined room beats a pending request, one the partner
// is in beats one they are not, one whose newest message is the tapped mirror
// beats the rest, and the most recently active room breaks remaining ties.
static ApolloChatRoomEntry *ApolloChatRoomDirectoryBest(NSArray<ApolloChatRoomEntry *> *candidates,
                                                       NSString *partnerUserId, NSTimeInterval messageTimestamp) {
    ApolloChatRoomEntry *best = nil;
    double bestScore = -1.0;
    for (ApolloChatRoomEntry *entry in candidates) {
        double score = 0.0;
        if (entry.joined) score += 4.0;
        if (partnerUserId.length && [entry.participants containsObject:partnerUserId]) score += 3.0;
        if (messageTimestamp > 0 && entry.lastMessageTs > 0 &&
            fabs(entry.lastMessageTs / 1000.0 - messageTimestamp) <= 5.0) score += 2.0;
        // Recency tiebreak, always below one full point.
        if (entry.lastMessageTs > 0) score += MIN(0.99, entry.lastMessageTs / 1.0e13);
        if (score > bestScore) {
            best = entry;
            bestScore = score;
        }
    }
    return best;
}

static NSString *ApolloChatRoomDirectoryMatch(NSString *subject, NSString *partnerFullname, NSTimeInterval messageTimestamp) {
    if (!sDirectoryRooms) return nil;
    NSString *partnerUserId = ApolloChatRoomDirectoryMatrixUserId(partnerFullname);
    NSMutableArray<ApolloChatRoomEntry *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^consider)(ApolloChatRoomEntry *) = ^(ApolloChatRoomEntry *entry) {
        if (!entry || [seen containsObject:entry.roomId]) return;
        if ([entry.chatType isEqualToString:@"reddit_modmail"]) return;   // moderator mail lives elsewhere
        [seen addObject:entry.roomId];
        [candidates addObject:entry];
    };

    if (ApolloChatSubjectIsRoomMarker(subject)) {
        // Unnamed room: the partner decides. The server's own m.direct map is
        // authoritative for direct chats; unnamed rooms the partner is in
        // (group rooms, older rooms with sparse state) fill in behind it.
        if (partnerUserId.length == 0) return nil;
        for (NSString *roomId in sDirectoryDirectRooms[partnerUserId] ?: @[]) {
            ApolloChatRoomEntry *entry = sDirectoryRooms[roomId];
            if (!entry) {
                // Listed by the server but not in the pages we fetched: still a
                // real direct room with this partner. Rank it below known ones.
                entry = [ApolloChatRoomEntry new];
                entry.roomId = roomId;
                entry.chatType = @"direct";
                [entry.participants addObject:partnerUserId];
            }
            consider(entry);
        }
        for (ApolloChatRoomEntry *entry in sDirectoryRooms.allValues) {
            if (entry.name.length > 0) continue;
            if ([entry.participants containsObject:partnerUserId]) consider(entry);
        }
    } else {
        NSString *trimmedSubject = ApolloChatRoomDirectoryTrim(subject);
        if (trimmedSubject.length == 0) return nil;
        // Exact title first; a whitespace- or case-insensitive match only when
        // nothing matched exactly (Reddit keeps the subject verbatim, trailing
        // spaces included).
        for (ApolloChatRoomEntry *entry in sDirectoryRooms.allValues) {
            if ([entry.name isEqualToString:subject]) consider(entry);
        }
        if (candidates.count == 0) {
            for (ApolloChatRoomEntry *entry in sDirectoryRooms.allValues) {
                if (entry.name.length == 0) continue;
                if ([ApolloChatRoomDirectoryTrim(entry.name) caseInsensitiveCompare:trimmedSubject] == NSOrderedSame) {
                    consider(entry);
                }
            }
        }
    }

    if (candidates.count == 0 && messageTimestamp > 0) {
        // Last resort for a room whose name never reached us: the mirror is a
        // verbatim copy of a chat message, so the room whose newest message
        // was sent at that exact moment is it — but only when unambiguous.
        for (ApolloChatRoomEntry *entry in sDirectoryRooms.allValues) {
            if (entry.lastMessageTs > 0 && fabs(entry.lastMessageTs / 1000.0 - messageTimestamp) <= 2.0) {
                consider(entry);
            }
        }
        if (candidates.count != 1) [candidates removeAllObjects];
    }

    ApolloChatRoomEntry *best = ApolloChatRoomDirectoryBest(candidates, partnerUserId, messageTimestamp);
    if (!best || !ApolloChatRoomDirectoryRoomIdIsSafe(best.roomId)) return nil;
    // A pending invitation has no openable room yet — Reddit answers its room
    // URL with the plain chat list. The Requests section is where it lives.
    if (best.invited && !best.joined) {
        ApolloLog(@"[ChatRooms] Mirror matched a pending chat request; routing to Requests");
        return ApolloChatRequestsPath;
    }
    return [@"/chat/room/" stringByAppendingString:best.roomId];
}

#pragma mark - Partner id lookup

// A partner's account id when no parsed message carried it (the tapped mirror
// was sent BY the active user, so `author_fullname` is our own). The stored web
// session's cookies answer www.reddit.com's profile JSON for any account mode.
static void ApolloChatRoomDirectoryLookupFullname(NSString *username, void (^completion)(NSString *fullname)) {
    NSString *known = ApolloChatRoomDirectoryKnownFullname(username);
    if (known.length > 0) {
        completion(known);
        return;
    }
    NSString *cookie = ApolloActiveWebSession().cookieHeader;
    NSString *escaped = [username stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLPathAllowedCharacterSet]];
    if (cookie.length == 0 || escaped.length == 0) {
        completion(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://www.reddit.com/user/%@/about.json?raw_json=1", escaped]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kRoomDirectoryRequestTimeout;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:cookie forHTTPHeaderField:@"Cookie"];
    [request setValue:kRoomDirectoryBrowserUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[ApolloChatRoomDirectorySession() dataTaskWithRequest:request
                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *fullname = nil;
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (!error && statusCode == 200 && data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *user = [parsed isKindOfClass:[NSDictionary class]] &&
                [parsed[@"data"] isKindOfClass:[NSDictionary class]] ? parsed[@"data"] : nil;
            NSString *identifier = [user[@"id"] isKindOfClass:[NSString class]] ? user[@"id"] : nil;
            if (identifier.length > 0) {
                fullname = [identifier hasPrefix:@"t2_"] ? identifier : [@"t2_" stringByAppendingString:identifier];
                ApolloChatRoomDirectoryNoteUserFullname(username, fullname);
            }
        }
        ApolloLog(@"[ChatRooms] Partner id lookup %@ (HTTP %ld)", fullname ? @"succeeded" : @"failed", (long)statusCode);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(fullname); });
    }] resume];
}

#pragma mark - Resolve

void ApolloChatRoomDirectoryResolve(NSString *subject, NSString *partner, NSTimeInterval messageTimestamp,
                                    void (^completion)(NSString *chatPath)) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloChatRoomDirectoryResolve(subject, partner, messageTimestamp, completion);
        });
        return;
    }
    __block BOOL finished = NO;
    void (^finish)(NSString *) = ^(NSString *path) {
        if (finished) return;
        finished = YES;
        completion(path);
    };
    // A tap must not hang on the network: past the deadline the caller opens
    // the legacy thread while any fetch in flight still warms the cache.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRoomDirectoryTapDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!finished) ApolloLog(@"[ChatRooms] Resolution took longer than %.0fs; giving up on this tap", kRoomDirectoryTapDeadline);
        finish(nil);
    });

    BOOL unnamed = ApolloChatSubjectIsRoomMarker(subject);
    NSString *knownFullname = ApolloChatRoomDirectoryKnownFullname(partner);
    void (^refetchIfStale)(void) = ^{
        if ([NSDate date].timeIntervalSince1970 - sDirectoryFetchedAt < kRoomDirectoryMissRefetchInterval) {
            finish(nil);
            return;
        }
        ApolloChatRoomDirectoryEnsure(YES, ^(BOOL ready) {
            NSString *fullname = ApolloChatRoomDirectoryKnownFullname(partner);
            finish(ready ? ApolloChatRoomDirectoryMatch(subject, fullname, messageTimestamp) : nil);
        });
    };
    ApolloChatRoomDirectoryEnsure(NO, ^(BOOL ready) {
        if (finished) return;
        if (!ready) {
            finish(nil);
            return;
        }
        NSString *path = ApolloChatRoomDirectoryMatch(subject, knownFullname, messageTimestamp);
        if (path) {
            finish(path);
            return;
        }
        if (unnamed && knownFullname.length == 0 && partner.length > 0) {
            ApolloChatRoomDirectoryLookupFullname(partner, ^(NSString *fullname) {
                if (finished) return;
                NSString *retry = fullname ? ApolloChatRoomDirectoryMatch(subject, fullname, messageTimestamp) : nil;
                if (retry) finish(retry);
                else refetchIfStale();
            });
            return;
        }
        refetchIfStale();
    });
}
