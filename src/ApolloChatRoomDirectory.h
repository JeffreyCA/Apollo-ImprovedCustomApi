#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Maps a legacy-inbox chat mirror back to the modern Chat room it came from.
//
// Since Reddit folded private messages into Chat, every chat message is also
// written into the old /message/inbox listing as a plain private message: a
// direct chat arrives with the subject "[direct chat room]" (group rooms use
// "[group chat room]"), and a converted message thread or titled group room
// arrives under the room's title. The mirror carries the participants and the
// text, but no room id at all — so opening it natively can only ever show
// Apollo's legacy thread UI.
//
// Reddit's chat backend is Matrix (matrix.redditspace.com); the poller already
// talks to it for unread counts. One filtered sync per account returns the
// room directory: each joined room's type (`com.reddit.chat.type`: direct /
// reddit_titled_direct / reddit_modmail), its participants, its name, and the
// account-level `m.direct` map of partner -> direct rooms. A titled room is
// named exactly after the old subject and a direct room is matched through the
// other participant's account id, which is how a tapped mirror finds its room.
// The directory is cached per account and refreshed when a lookup misses.

// Warm the directory for the active account (a no-op while it is fresh, with
// modern Chat off, or without a stored web session). Safe from any thread.
void ApolloChatRoomDirectoryPrefetch(void);

// YES for the bracketed whole-subject marker Reddit stamps on unnamed chat
// mirrors ("[direct chat room]" / "[group chat room]"): exactly one bracket pair
// spanning the trimmed subject and ending in "chat room", so a real subject
// that merely mentions a chat room never qualifies.
BOOL ApolloChatSubjectIsRoomMarker(NSString * _Nullable subject);

// Remember a user's account fullname ("t2_…") seen while parsing message JSON.
// Mirrors carry `author_fullname`, which RDKMessage drops; direct rooms are
// keyed by that id. Safe from any thread.
void ApolloChatRoomDirectoryNoteUserFullname(NSString * _Nullable username, NSString * _Nullable fullname);

// Resolve the Chat path for a mirror: "/chat/room/<id>" for a room the account
// has joined, or ApolloChatRequestsPath when the matched room is still a
// pending invitation (someone the account never chatted with wrote first, so
// Reddit files the conversation under Chat > Requests until it is accepted —
// its room URL only bounces to the chat list). `subject` is the message
// subject, `partner` the OTHER participant's username (nil when unknown or
// deleted), `messageTimestamp` the mirror's creation time in seconds since
// 1970 (0 = unknown; used to tell same-named rooms apart). The completion runs
// on the main queue — with nil when no room could be matched, the directory
// could not be fetched, or the lookup took longer than a tap should wait — so
// the caller can fall back to Apollo's legacy thread.
extern NSString * const ApolloChatRequestsPath;
void ApolloChatRoomDirectoryResolve(NSString * _Nullable subject,
                                    NSString * _Nullable partner,
                                    NSTimeInterval messageTimestamp,
                                    void (^completion)(NSString * _Nullable chatPath));

__END_DECLS

NS_ASSUME_NONNULL_END
