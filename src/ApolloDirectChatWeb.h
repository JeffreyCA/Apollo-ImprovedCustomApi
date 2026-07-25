#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The Inbox Chat surface presents Reddit's modern conversation list as three
// Apollo-owned tabs. Messages uses Reddit's /chat conversation list, Requests
// uses /chat/requests, and Threads uses Reddit's real /chat/threads page for
// side conversations created from replies to individual chat messages.
typedef NS_ENUM(NSInteger, ApolloModernChatInboxSection) {
    ApolloModernChatInboxSectionMessages = 0,
    ApolloModernChatInboxSectionRequests,
    ApolloModernChatInboxSectionThreads,
};

@class ApolloWebSessionEntry;

__BEGIN_DECLS

// Modern reddit.com (shreddit) fails to render below iOS 16 — the same floor
// the web-session login enforces by rewriting to old.reddit.com. Every modern
// Chat/Modmail gate below returns NO under it, so pre-16 devices keep
// Apollo's stock (dormant) chat UI instead of a blank web page.
BOOL ApolloModernMailboxOSSupported(void);
BOOL ApolloModernChatIsAvailable(void);
BOOL ApolloModernChatIsRequiredForActiveAccount(void);
// Per-session variant for callers that already resolved the active account's
// web-session entry (the 30s unread poller): identical verdict to
// ApolloModernChatIsRequiredForActiveAccount without re-unarchiving the
// account blob or re-reading the keychain.
BOOL ApolloModernChatIsRequiredForSession(ApolloWebSessionEntry * _Nullable entry);
BOOL ApolloModernChatShouldOpen(void);
BOOL ApolloModernModmailShouldOpen(void);
// YES iff `controller` (a modern mailbox controller) was cookie-seeded for
// the account that is active RIGHT NOW. The persistent Inbox Chat hub uses
// this to detect account switches and cookie rotations, so a retained hub can
// never keep showing — or composing as — a previous account.
BOOL ApolloModernChatControllerSessionIsCurrent(UIViewController * _Nullable controller);
UIColor *ApolloModernChatThemeColor(UITraitCollection *traits, NSString *role);
NSDictionary<NSString *, id> * _Nullable ApolloModernChatCachedStatus(void);
extern NSString * const ApolloModernChatStatusDidChangeNotification;
// Authoritative full-state publish from the background unread poller
// (ApolloChatUnreadPoller.m): {username, unreadCount, requestsCount,
// preview?, unreadRoomId?, checkedAt}. Unlike the webview DOM scrape, one
// polled snapshot covers both the messages and requests surfaces at once,
// with exact counts.
void ApolloModernChatPublishPolledStatus(NSDictionary<NSString *, id> *status);
UIViewController *ApolloCreateModernChatViewController(void);
// Notification/deep-link entry point. The optional destination must be a
// Reddit Chat path such as /chat/room/<opaque-room-id>; invalid paths safely
// fall back to the normal Chat entry screen.
UIViewController *ApolloCreateModernChatViewControllerForPath(NSString * _Nullable destinationPath);
// Inbox-only variant. It embeds the authenticated web client below Apollo's
// Notifications / Chat and Messages / Requests / Threads controls instead of
// pushing a second full-screen Chat controller.
UIViewController *ApolloCreateEmbeddedModernChatViewController(ApolloModernChatInboxSection section);
void ApolloModernChatControllerShowInboxSection(UIViewController *controller,
                                                ApolloModernChatInboxSection section);
// The in-place Inbox hub does not trigger child appearance callbacks when it
// cross-fades between Notifications and Chat. Explicitly hand shared tab-bar
// ownership to the web controller while Chat is visible, and restore it when
// Notifications returns.
void ApolloModernChatControllerSetInboxVisible(UIViewController *controller, BOOL visible);
void ApolloModernChatControllerRefreshEmbeddedLayout(UIViewController *controller);
// API-key-free accounts cannot use Apollo's OAuth-only native new-Modmail
// endpoints. This presents Reddit's current cookie-authenticated Modmail inbox
// in the same isolated, Apollo-themed mailbox shell as modern Chat.
UIViewController *ApolloCreateModernModmailViewController(void);
// Notification/deep-link entry point. The optional destination must be a
// Reddit Modmail path such as /mail/all/<opaque-conversation-id>.
UIViewController *ApolloCreateModernModmailViewControllerForPath(NSString * _Nullable destinationPath);

__END_DECLS

NS_ASSUME_NONNULL_END
