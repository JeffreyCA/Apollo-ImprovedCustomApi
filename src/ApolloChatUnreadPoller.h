#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Background unread poller for the modern Reddit Chat mailbox.
//
// The Chat webview only knows its unread state while it is open, so on its own
// the Inbox badge stays stale until the user visits Chat. This module polls
// Reddit's Chat backend directly over HTTP — no webview involved — and feeds
// the results into the same cached status + change notification the badge,
// mode switcher, and section switcher already consume.
//
// Reddit's modern Chat is Matrix: the web client at www.reddit.com/chat talks
// to the homeserver at matrix.redditspace.com, authenticating with the
// account's `token_v2` cookie value as a plain OAuth bearer (verified live —
// /_matrix/client/v3/account/whoami accepts it directly). A filtered /sync
// with timeout=0 returns Reddit's own pre-computed counters at the top level:
//
//   com.reddit.global_navigation_counter  — unread messages (the number
//                                           reddit.com badges its chat bubble
//                                           with)
//   com.reddit.invites_counter            — pending chat requests
//
// plus per-room unread_notifications and a one-event timeline for previews.
// Incremental polls (with a `since` token) are ~2 KB, so a 30 s foreground
// cadence is cheaper than a single feed image.
//
// The poller only runs when the modern Chat surface is actually in use (the
// Use Modern Reddit Chat preference, which applies to API-key and API-key-free
// accounts alike) and the active account has a stored web session. With the
// feature off it never fires, so stock Apollo behavior is untouched.

// Ask the poller to refresh soon (coalesced; safe from any thread). Used by
// UI that wants a fresher count than the periodic cadence, e.g. when the
// Inbox becomes visible.
void ApolloChatUnreadPollerKick(void);

// A Matrix bearer for the active account: the cached poller token, the stored
// cookie's still-fresh token_v2, a fresh one from a live mailbox web view (see
// the provider below), or a mint — nil when none is obtainable right now (no
// web session, modern Chat unsupported, a dead session in its backoff).
// Main queue in and out. Shared with the chat room directory.
void ApolloChatPollObtainBearerForActiveAccount(void (^completion)(NSString * _Nullable bearer));
// The modern mailbox web views load real reddit.com documents, and Reddit
// refreshes token_v2 on those — their cookie jar is a free bearer source the
// poller consults before an offscreen mint. Registered by ApolloDirectChatWeb;
// the provider answers nil when no current-account web view is alive.
void ApolloChatPollSetWebJarBearerProvider(void (^ _Nullable provider)(void (^completion)(NSString * _Nullable token)));
// A request made with `bearer` came back 401/403: forget it so the next
// request harvests or mints a fresh token instead of retrying a dead one.
void ApolloChatPollNoteBearerRejected(NSString * _Nullable bearer);
// Homeserver base URL, honouring the simulator debug override.
NSString *ApolloChatPollHomeserver(void);

__END_DECLS

NS_ASSUME_NONNULL_END
