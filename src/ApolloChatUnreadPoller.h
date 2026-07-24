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
// The poller only runs when the modern Chat surface is actually in use
// (ApolloModernChatShouldOpen() — forced on for API-key-free accounts, opt-in
// for API-key accounts) and the active account has a stored web session. With
// the feature off it never fires, so stock Apollo behavior is untouched.

// Ask the poller to refresh soon (coalesced; safe from any thread). Used by
// UI that wants a fresher count than the periodic cadence, e.g. when the
// Inbox becomes visible.
void ApolloChatUnreadPollerKick(void);

__END_DECLS

NS_ASSUME_NONNULL_END
