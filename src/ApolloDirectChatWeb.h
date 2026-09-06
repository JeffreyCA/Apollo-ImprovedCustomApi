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
// Both surfaces are a plain user preference — they work for API-key and
// API-key-free accounts alike, and off means Apollo's own Direct Chat /
// Moderator Mail, which need Reddit API credentials.
BOOL ApolloModernChatShouldOpen(void);
BOOL ApolloModernModmailShouldOpen(void);
// One-time: records the previously implied "on" for setups that were getting
// modern Chat/Modmail from the old forced gate, so switching to a plain
// preference cannot silently remove either surface. Safe to call repeatedly.
void ApolloMigrateModernMailboxPreferences(void);
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
// Open a conversation inside an existing Chat controller (the Inbox hub's, or
// a standalone one): a validated Reddit Chat conversation path such as
// /chat/room/<opaque-room-id> loads as a real navigation under the same
// covered transition a tapped room gets, in the Messages section. A controller
// that has not loaded its first document yet takes it as its initial
// destination instead. Anything else is ignored.
void ApolloModernChatControllerOpenConversationPath(UIViewController *controller, NSString *path);
void ApolloModernChatControllerRefreshEmbeddedLayout(UIViewController *controller);
// YES while `controller` (a modern Chat controller) is inside a conversation
// (/chat/room/… or a /chat/threads/<id> reply thread) rather than one of the
// list surfaces — by the web view's route, or by the page's own report of a
// conversation pane on screen when a same-document room open delivered no
// URL change. The Inbox hub's back-swipe tracker checks this to decide
// which level of the hierarchy one gesture climbs: out of the conversation
// while one is open, otherwise Chat -> Notifications.
BOOL ApolloModernChatControllerIsOnConversationRoute(UIViewController * _Nullable controller);
// Climbs that first level: from an open conversation back to the list it was
// opened from, by clicking Reddit's own in-room Back control — the same
// instant pane flip a tap performs, URL repair and all. Returns YES when the
// caller's gesture was consumed (a back was issued, or one is still in
// flight) and NO when `controller` is not a modern Chat controller inside a
// conversation, in which case the caller keeps its own behavior.
BOOL ApolloModernChatControllerGoBackToConversationList(UIViewController * _Nullable controller);
// Interactive form of that same step, for a gesture that should feel like
// every other iOS back: Begin sets up the conversation over a still frame of
// the list it was opened from (NO if there is nothing to reveal, or a back is
// already running — the caller then falls back to the plain call above),
// Update tracks the drag in 0...1, and Finish either completes the step or
// puts the conversation back with the web view never touched.
BOOL ApolloModernChatControllerBeginInteractiveBack(UIViewController * _Nullable controller);
void ApolloModernChatControllerUpdateInteractiveBack(UIViewController * _Nullable controller,
                                                     CGFloat progress);
void ApolloModernChatControllerFinishInteractiveBack(UIViewController * _Nullable controller,
                                                     BOOL commit, CGFloat velocity);
// The gesture rules the two chat-hierarchy swipes share (the Inbox hub's
// mode-pan and the standalone Chat screen's own back-pan). YES when `pan`
// starts over horizontally scrollable web content inside `hostView` (a
// carousel in a bubble), which keeps its drag; and the release rule — commit
// past the halfway point, or on a decisive same-direction throw.
BOOL ApolloModernChatPanStartsOverHorizontalScroller(UIPanGestureRecognizer * _Nullable pan,
                                                     UIView * _Nullable hostView);
BOOL ApolloModernChatBackSwipeCommits(UIGestureRecognizerState state, CGFloat progress,
                                      CGFloat velocity, CGPoint translation);
// API-key-free accounts cannot use Apollo's OAuth-only native new-Modmail
// endpoints. This presents Reddit's current cookie-authenticated Modmail inbox
// in the same isolated, Apollo-themed mailbox shell as modern Chat.
UIViewController *ApolloCreateModernModmailViewController(void);
// Notification/deep-link entry point. The optional destination must be a
// Reddit Modmail path such as /mail/all/<opaque-conversation-id>.
UIViewController *ApolloCreateModernModmailViewControllerForPath(NSString * _Nullable destinationPath);

__END_DECLS

NS_ASSUME_NONNULL_END
