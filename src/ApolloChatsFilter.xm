// ApolloChatsFilter.xm
//
// Add a "Direct Chat" row to the inbox "Boxes" list, directly above
// "Messages". API-key-free accounts open Reddit's authenticated modern Chat
// client because current Chat is no longer mirrored through /message. API-key
// accounts can choose modern Chat or keep Apollo's legacy filtered list.
//
// Boxes screen = _TtC6Apollo23InboxListViewController (a UITableViewController whose
// data-source methods are ObjC-visible). The "Messages" row maps to InboxType.messages and
// pushes a _TtC6Apollo19InboxViewController (inboxType=messages, messages:[RDKMessage],
// IGListKit listAdapter). We:
//   1. Detect the Messages section by the stock cell's text (layout is account-dependent).
//   2. Add one extra row at the top of that section, styled "Direct Chat".
//   3. On tap, open modern Reddit Chat when selected/required; otherwise invoke
//      the real Messages row as a legacy fallback.
//   4. In that fallback, filter the IGListKit objects to chat-subject messages.

#import "ApolloChatRoomDirectory.h"
#import "ApolloChatUnreadPoller.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloWebSessionStore.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ChatsFilterLog(fmt, ...) ApolloLogDebug(@"[ChatsFilter] " fmt, ##__VA_ARGS__)

// Row discovery must be scoped to each InboxListViewController. Apollo can keep
// more than one Boxes controller alive while accounts/tabs change; global row
// coordinates make one controller rewrite another controller's section.
@interface ApolloBoxesRowState : NSObject
@property (nonatomic, assign) NSInteger messagesSection;
@property (nonatomic, assign) NSInteger messagesRow;
@property (nonatomic, assign) NSInteger moderatorMailSection;
@property (nonatomic, assign) NSInteger moderatorMailRow;
@property (nonatomic, assign) NSInteger nativeDirectChatSection;
@property (nonatomic, assign) NSInteger nativeDirectChatRow;
@end

@implementation ApolloBoxesRowState
- (instancetype)init {
    self = [super init];
    if (self) {
        _messagesSection = _messagesRow = -1;
        _moderatorMailSection = _moderatorMailRow = -1;
        _nativeDirectChatSection = _nativeDirectChatRow = -1;
    }
    return self;
}
@end

static char kApolloBoxesRowStateKey;
static ApolloBoxesRowState *ApolloBoxesState(id controller, BOOL create) {
    ApolloBoxesRowState *state = objc_getAssociatedObject(controller, &kApolloBoxesRowStateKey);
    if (!state && create) {
        state = [ApolloBoxesRowState new];
        objc_setAssociatedObject(controller, &kApolloBoxesRowStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

// Current Apollo builds already expose a native Direct Chat row for some
// accounts. Reuse it instead of adding a duplicate; insertion remains as a
// compatibility fallback for builds/account states where Apollo omits it.
static const BOOL sDirectChatRowEnabled = YES;
static BOOL sNextInboxIsChatFilter = NO;    // armed when the Direct Chat row is tapped
static char kChatFilterKey;                 // on InboxViewController: this list is chat-filtered
static __weak id sLatestBoxesController = nil;
static char kInboxAllModeSwitcherKey;
static char kInboxAllOriginalHeaderKey;
static char kInboxAllSwitcherTableKey;
static char kInboxAllSwitcherRefKey;
static char kInboxAllFadeGenerationKey;
static char kInboxAllShowPendingKey;
static char kInboxAllNavigationBackdropKey;
static char kInboxRefreshHapticKey;
static char kInboxAllStatusObserverKey;
static char kInboxAllChatHubKey;
static char kInboxAllChatHubVisibleKey;
static char kInboxAllOriginalRightItemsKey;

// Apollo owns the Inbox badge for notification/message counts. Keep that raw
// value separately and render Chat as an additive overlay so either producer
// can update independently without erasing the other.
static __weak UITabBarItem *sApolloInboxTabBarItem = nil;
static char kApolloInboxNativeBadgeValueKey;
static char kApolloInboxBadgeInitializedKey;
static char kApolloInboxApplyingCombinedBadgeKey;
static id sApolloModernChatBadgeObserver = nil;

static NSInteger ApolloModernChatUnreadBadgeCount(void) {
    if (!ApolloModernChatShouldOpen()) return 0;
    NSDictionary<NSString *, id> *status = ApolloModernChatCachedStatus();
    if (![status[@"hasUnread"] boolValue]) return 0;
    NSInteger exact = MAX(0, [status[@"threadUnreadCount"] integerValue]);
    // Reddit's global navigation counter may already fold pending requests
    // in, so only fall back to the exact requests count (background poller)
    // when no message count is available — never sum the two, which could
    // double-count. When only an unread/request marker is known (webview DOM
    // scrape), show one rather than pretending a precise number is known.
    if (exact == 0) exact = MAX(0, [status[@"requestsCount"] integerValue]);
    return MAX(1, exact);
}

static BOOL ApolloBadgeValueIsInteger(NSString *value, NSInteger *integer) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    NSInteger parsed = 0;
    BOOL valid = [scanner scanInteger:&parsed] && scanner.isAtEnd;
    if (valid && integer) *integer = MAX(0, parsed);
    return valid;
}

// An OAuth (API-key) account fetches its inbox through Reddit's API, which
// mirrors every chat conversation into it — so Apollo's own unread count
// already includes chats. An API-key-free account fetches over cookie
// transport, which carries no chat mirrors at all.
static BOOL ApolloNativeInboxListsChatMirrors(void) {
    return ApolloModernChatShouldOpen() && ApolloActiveWebSession() == nil;
}

static NSString *ApolloCombinedInboxBadgeValue(NSString *nativeValue) {
    NSInteger chatCount = ApolloModernChatUnreadBadgeCount();
    if (chatCount <= 0) return nativeValue;

    NSInteger nativeCount = 0;
    if (ApolloBadgeValueIsInteger(nativeValue, &nativeCount)) {
        // Where the native inbox already counts unread chat conversations,
        // adding the Chat count on top would count every unread chat twice.
        // Keep whichever signal is larger instead: the Chat count is the
        // fresher one (30s poll) until Apollo's next inbox refresh folds the
        // same unreads into its own number. Without mirrors the two sets are
        // disjoint and still add up.
        NSInteger combined = ApolloNativeInboxListsChatMirrors()
            ? MAX(nativeCount, chatCount) : nativeCount + chatCount;
        return [NSString stringWithFormat:@"%ld", (long)combined];
    }
    // Apollo normally supplies a number or nil. If it supplies a symbolic dot,
    // prefer the useful Chat count; preserve threshold strings such as 99+.
    if (nativeValue.length > 0 && ![nativeValue isEqualToString:@"•"]) return nativeValue;
    return [NSString stringWithFormat:@"%ld", (long)chatCount];
}

// The Inbox tab bar item is normally captured when Apollo touches its badge
// or the user visits the Inbox — neither is guaranteed by launch. A chat-only
// unread (background poller, no native unreads, Inbox never opened) must
// still be able to badge the tab, so fall back to locating the item by title
// on a window's tab bar controller, exactly the identity check the
// setBadgeValue: hook below uses.
static void ApolloEnsureInboxTabBarItemCaptured(void) {
    if (sApolloInboxTabBarItem) return;
    for (UIWindow *window in ApolloAllWindows()) {
        UIViewController *root = window.rootViewController;
        if (![root isKindOfClass:[UITabBarController class]]) continue;
        for (UITabBarItem *item in ((UITabBarController *)root).tabBar.items) {
            if (item.title.length == 0 ||
                [item.title caseInsensitiveCompare:@"Inbox"] != NSOrderedSame) continue;
            sApolloInboxTabBarItem = item;
            if (![objc_getAssociatedObject(item, &kApolloInboxBadgeInitializedKey) boolValue]) {
                objc_setAssociatedObject(item, &kApolloInboxNativeBadgeValueKey,
                                         item.badgeValue, OBJC_ASSOCIATION_COPY_NONATOMIC);
                objc_setAssociatedObject(item, &kApolloInboxBadgeInitializedKey,
                                         @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            ChatsFilterLog(@"captured Inbox tab bar item by title fallback");
            return;
        }
    }
}

static void ApolloApplyCombinedInboxBadge(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloApplyCombinedInboxBadge(); });
        return;
    }
    ApolloEnsureInboxTabBarItemCaptured();
    UITabBarItem *item = sApolloInboxTabBarItem;
    if (!item || ![objc_getAssociatedObject(item, &kApolloInboxBadgeInitializedKey) boolValue]) return;
    NSString *nativeValue = objc_getAssociatedObject(item, &kApolloInboxNativeBadgeValueKey);
    objc_setAssociatedObject(item, &kApolloInboxApplyingCombinedBadgeKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    item.badgeValue = ApolloCombinedInboxBadgeValue(nativeValue);
    objc_setAssociatedObject(item, &kApolloInboxApplyingCombinedBadgeKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloCaptureInboxTabBarItem(UIViewController *controller) {
    UITabBarItem *item = controller.navigationController.tabBarItem ?: controller.tabBarItem;
    if (!item) return;
    sApolloInboxTabBarItem = item;
    if (![objc_getAssociatedObject(item, &kApolloInboxBadgeInitializedKey) boolValue]) {
        objc_setAssociatedObject(item, &kApolloInboxNativeBadgeValueKey,
                                 item.badgeValue, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(item, &kApolloInboxBadgeInitializedKey,
                                 @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloApplyCombinedInboxBadge();
}

// Modern Chat makes the row useful for cookie-auth API-free accounts as well as
// OAuth accounts, so it remains present for every signed-in account.
static BOOL ApolloDirectChatRowActive(void) { return sDirectChatRowEnabled; }

#pragma mark - helpers

// Find the cell's primary text whether it uses textLabel or a custom UILabel subview.
static NSString *ApolloCellText(UITableViewCell *cell) {
    if (cell.textLabel.text.length) return cell.textLabel.text;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) return ((UILabel *)v).text;
        [q addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void ApolloRestyleAsDirectChat(UITableViewCell *cell) {
    if (!cell) return;
    // IconTextTableViewCell uses a CUSTOM label, not cell.textLabel (which is lazy and always
    // non-nil — setting it just overlays a 2nd "Direct Chat" on top of "Messages"). Find the
    // label that actually shows the row text and the leading icon image view, and relabel both.
    UILabel *label = nil; UIImageView *icon = nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:cell.contentView];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if (!label && [v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) label = (UILabel *)v;
        if (!icon  && [v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image) icon = (UIImageView *)v;
        [q addObjectsFromArray:v.subviews];
    }
    if (label) label.text = @"Direct Chat";
    if (@available(iOS 13.0, *)) {
        UIImage *glyph = [UIImage systemImageNamed:@"bubble.left.and.bubble.right"];
        if (icon && glyph) icon.image = [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

static void ApolloRememberSpecialBoxesCell(ApolloBoxesRowState *state,
                                            UITableViewCell *cell,
                                            NSIndexPath *indexPath) {
    if (!cell || !indexPath) return;
    NSString *text = ApolloCellText(cell);
    if ([text isEqualToString:@"Moderator Mail"] || [text isEqualToString:@"Mod Mail"]) {
        state.moderatorMailSection = indexPath.section;
        state.moderatorMailRow = indexPath.row;
        ChatsFilterLog(@"Moderator Mail at s=%ld r=%ld", (long)indexPath.section, (long)indexPath.row);
    } else if ([text isEqualToString:@"Direct Chat"]) {
        state.nativeDirectChatSection = indexPath.section;
        state.nativeDirectChatRow = indexPath.row;
        ChatsFilterLog(@"native Direct Chat at s=%ld r=%ld", (long)indexPath.section, (long)indexPath.row);
    }
}

static BOOL ApolloBoxesHasNativeDirectChat(ApolloBoxesRowState *state) {
    return state.nativeDirectChatSection >= 0 &&
           state.nativeDirectChatSection == state.messagesSection &&
           state.nativeDirectChatRow >= 0;
}

static BOOL ApolloBoxesUsesInsertedDirectChat(ApolloBoxesRowState *state) {
    return state.messagesSection >= 0 && !ApolloBoxesHasNativeDirectChat(state);
}

// Apollo builds the Boxes sections synchronously from currentUser.isMod / the
// moderated-subreddits array. During an API-key-free sign-in the account-change
// notification can arrive before those models finish hydrating, so refresh the
// already-visible root a couple of times after a switch. This lets Moderator
// Mail appear without requiring a relaunch.
static UITableView *ApolloBoxesTableView(id controller) {
    if (!controller) return nil;
    Ivar ivar = class_getInstanceVariable([controller class], "tableView");
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:[UITableView class]] ? value : nil;
}

// Our tableView:numberOfRowsInSection: adds +1 to the Messages section while the
// row state names a messagesSection (ApolloBoxesUsesInsertedDirectChat). A fresh
// state has messagesSection == -1, so simply swapping the state object out drops
// that row from the count with no delete to match — and if a table update was
// already in flight, UIKit's row-count assertion fires inside
// -[ASTableView rangeController:updateWithChangeSet:updates:]. That is issue #865:
// switching accounts with the inbox on screen.
//
// Reset and reload as one main-queue step instead, so the count only ever changes
// at a moment the table is being told to re-read it from scratch.
static void ApolloBoxesResetRowStateAndReload(id controller, NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!controller) return;
        UITableView *tableView = ApolloBoxesTableView(controller);
        objc_setAssociatedObject(controller, &kApolloBoxesRowStateKey,
                                 [ApolloBoxesRowState new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tableView reloadData];
        ChatsFilterLog(@"reset Boxes row state + reloaded (%@)", reason ?: @"unknown");
    });
}

static void ApolloRefreshBoxesForModeratorState(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id controller = sLatestBoxesController;
        UITableView *tableView = ApolloBoxesTableView(controller);
        if (!tableView) return;
        [tableView reloadData];
        ChatsFilterLog(@"reloaded Boxes after moderator state update (%@)", reason ?: @"unknown");
    });
}

#pragma mark - Inbox (All): Notifications / Chat switcher

typedef NS_ENUM(NSInteger, ApolloInboxMode) {
    ApolloInboxModeNotifications = 0,
    ApolloInboxModeChat = 1,
};

// Keep Chat beside the existing notifications instead of presenting it as a
// large promotional card. This deliberately behaves like a two-tab switcher.
// On Liquid Glass builds it embeds a real UISegmentedControl so it gets the
// native glass thumb, morphing, and accessibility for free (tinted with the
// theme accent); everywhere else it stays hand-drawn with ordinary UIKit so
// it follows every Apollo theme rather than inheriting the stock blue
// segmented-control appearance. Both variants expose the same external API,
// so ApolloSetInboxChatHubVisible / ApolloInstallInboxModeSwitcher never care
// which one is live.
@interface ApolloInboxModeSwitcherView : UIControl
@property (nonatomic, strong) UISegmentedControl *segmentedControl;   // Liquid Glass builds only
// Last theme colors actually applied to the segmented control. Re-applying
// selectedSegmentTintColor / title attributes rebuilds the segments, which
// cancels an in-flight Liquid Glass thumb morph — so appearance writes only
// happen when a color really changed (status refreshes arrive every few
// seconds and would otherwise stomp every user tap's animation).
@property (nonatomic, strong) UIColor *lastAppliedAccent;             // Liquid Glass builds only
@property (nonatomic, strong) UIColor *lastAppliedText;               // Liquid Glass builds only
@property (nonatomic, strong) UIColor *lastAppliedSelectedText;       // Liquid Glass builds only
@property (nonatomic, strong) UIView *containerView;                  // custom (non-LG) drawing
@property (nonatomic, strong) UIView *selectionView;
@property (nonatomic, strong) UIButton *notificationsButton;
@property (nonatomic, strong) UIButton *chatButton;
@property (nonatomic, strong) UILabel *chatUnreadBadge;
@property (nonatomic, assign) ApolloInboxMode selectedMode;
- (void)apollo_setSelectedMode:(ApolloInboxMode)mode animated:(BOOL)animated;
- (void)apollo_refreshForTraits:(UITraitCollection *)traits;
@end

@implementation ApolloInboxModeSwitcherView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    if (IsLiquidGlass()) {
        self.segmentedControl = [[UISegmentedControl alloc]
            initWithItems:@[@"Notifications", @"Chat"]];
        self.segmentedControl.selectedSegmentIndex = 0;
        [self.segmentedControl addTarget:self
                                  action:@selector(apollo_segmentChanged:)
                        forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.segmentedControl];

        // Same numeric unread pill as the custom variant, overlaid on the
        // Chat segment (UISegmentedControl has no badge API, and digging into
        // its private segment subviews would be brittle).
        self.chatUnreadBadge = [UILabel new];
        self.chatUnreadBadge.userInteractionEnabled = NO;
        self.chatUnreadBadge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        self.chatUnreadBadge.textAlignment = NSTextAlignmentCenter;
        self.chatUnreadBadge.layer.cornerRadius = 9.0;
        self.chatUnreadBadge.clipsToBounds = YES;
        self.chatUnreadBadge.hidden = YES;
        // The count is spoken via the control's accessibilityValue; the pill
        // itself must not appear as a second VoiceOver element.
        self.chatUnreadBadge.isAccessibilityElement = NO;
        [self addSubview:self.chatUnreadBadge];

        _selectedMode = ApolloInboxModeNotifications;
        return self;
    }

    self.containerView = [UIView new];
    self.containerView.userInteractionEnabled = YES;
    self.containerView.layer.cornerRadius = 12.0;
    self.containerView.layer.borderWidth = 0.5;
    self.containerView.clipsToBounds = YES;
    [self addSubview:self.containerView];

    self.selectionView = [UIView new];
    self.selectionView.userInteractionEnabled = NO;
    self.selectionView.layer.cornerRadius = 9.0;
    [self.containerView addSubview:self.selectionView];

    self.notificationsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.notificationsButton setTitle:@"Notifications" forState:UIControlStateNormal];
    self.notificationsButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.notificationsButton.accessibilityLabel = @"Notifications";
    [self.notificationsButton addTarget:self action:@selector(apollo_buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.containerView addSubview:self.notificationsButton];

    self.chatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.chatButton setTitle:@"Chat" forState:UIControlStateNormal];
    self.chatButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.chatButton.accessibilityLabel = @"Chat";
    [self.chatButton addTarget:self action:@selector(apollo_buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.containerView addSubview:self.chatButton];

    // Numeric unread pill beside the "Chat" title (the background poller
    // supplies exact counts, so a bare dot undersells the state).
    self.chatUnreadBadge = [UILabel new];
    self.chatUnreadBadge.userInteractionEnabled = NO;
    self.chatUnreadBadge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    self.chatUnreadBadge.textAlignment = NSTextAlignmentCenter;
    self.chatUnreadBadge.layer.cornerRadius = 9.0;
    self.chatUnreadBadge.clipsToBounds = YES;
    self.chatUnreadBadge.hidden = YES;
    // The count is spoken via chatButton.accessibilityValue; the pill itself
    // must not appear as a second VoiceOver element.
    self.chatUnreadBadge.isAccessibilityElement = NO;
    [self.containerView addSubview:self.chatUnreadBadge];

    _selectedMode = ApolloInboxModeNotifications;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGRectGetWidth(self.bounds) <= 24.0 || CGRectGetHeight(self.bounds) <= 16.0) return;

    CGFloat badgeWidth = 18.0;
    if (self.chatUnreadBadge.text.length > 1) {
        CGSize textSize = [self.chatUnreadBadge.text sizeWithAttributes:
                           @{NSFontAttributeName: self.chatUnreadBadge.font}];
        badgeWidth = MAX(18.0, ceil(textSize.width) + 10.0);
    }

    if (self.segmentedControl) {
        // Native control at its intrinsic Liquid Glass height, centered in
        // the same 60pt strip the custom variant fills.
        CGFloat controlHeight = self.segmentedControl.intrinsicContentSize.height;
        if (controlHeight <= 0) controlHeight = 32.0;
        controlHeight = MIN(controlHeight, CGRectGetHeight(self.bounds) - 12.0);
        CGRect controlFrame = CGRectMake(12.0,
                                         floor((CGRectGetHeight(self.bounds) - controlHeight) / 2.0),
                                         CGRectGetWidth(self.bounds) - 24.0, controlHeight);
        self.segmentedControl.frame = controlFrame;
        // Overlay the pill beside the "Chat" title (right segment's midpoint,
        // same +20pt offset as the custom variant).
        CGFloat chatSegmentMidX = CGRectGetMinX(controlFrame) + controlFrame.size.width * 0.75;
        self.chatUnreadBadge.frame = CGRectMake(chatSegmentMidX + 20.0,
                                                CGRectGetMidY(controlFrame) - 9.0, badgeWidth, 18.0);
        return;
    }

    self.containerView.frame = CGRectInset(self.bounds, 12.0, 8.0);
    CGRect content = CGRectInset(self.containerView.bounds, 3.0, 3.0);
    CGFloat halfWidth = floor(content.size.width / 2.0);
    CGRect notificationsFrame = CGRectMake(content.origin.x, content.origin.y, halfWidth, content.size.height);
    CGRect chatFrame = CGRectMake(CGRectGetMaxX(notificationsFrame), content.origin.y,
                                  content.size.width - halfWidth, content.size.height);
    self.notificationsButton.frame = notificationsFrame;
    self.chatButton.frame = chatFrame;
    self.selectionView.frame = self.selectedMode == ApolloInboxModeChat ? chatFrame : notificationsFrame;
    self.chatUnreadBadge.frame = CGRectMake(CGRectGetMidX(chatFrame) + 20.0,
                                            CGRectGetMidY(chatFrame) - 9.0, badgeWidth, 18.0);
}

- (void)apollo_buttonTapped:(UIButton *)sender {
    ApolloInboxMode mode = sender == self.chatButton ? ApolloInboxModeChat : ApolloInboxModeNotifications;
    [self apollo_setSelectedMode:mode animated:YES];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)apollo_segmentChanged:(UISegmentedControl *)sender {
    _selectedMode = sender.selectedSegmentIndex == 1 ? ApolloInboxModeChat : ApolloInboxModeNotifications;
    // Deliberately no theme refresh here: nothing tap-dependent changes (the
    // selected-state title attributes are state-based, so UIKit swaps them
    // itself), and touching the control now would cancel the Liquid Glass
    // thumb morph that this very tap just started.
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)apollo_setSelectedMode:(ApolloInboxMode)mode animated:(BOOL)animated {
    _selectedMode = mode;
    if (self.segmentedControl) {
        // Programmatic index changes never re-fire apollo_segmentChanged:
        // (UIKit only sends valueChanged for user interaction), so the two
        // synced switcher instances cannot ping-pong. When the control is
        // already on the target segment — the common case of the tapped
        // instance being synced back by ApolloSetInboxChatHubVisible /
        // ApolloInstallInboxModeSwitcher — leave it completely untouched:
        // any write here snaps the tap's in-flight Liquid Glass thumb morph.
        NSInteger targetIndex = mode == ApolloInboxModeChat ? 1 : 0;
        if (self.segmentedControl.selectedSegmentIndex != targetIndex) {
            self.segmentedControl.selectedSegmentIndex = targetIndex;
        }
        return;
    }
    void (^changes)(void) = ^{
        [self setNeedsLayout];
        if (CGRectGetWidth(self.bounds) > 24.0 && CGRectGetHeight(self.bounds) > 16.0) {
            [self layoutIfNeeded];
        }
    };
    if (animated && self.window) {
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:changes completion:nil];
    } else {
        changes();
    }
    [self apollo_refreshForTraits:self.traitCollection];
}

- (void)apollo_refreshForTraits:(UITraitCollection *)traits {
    NSInteger unreadCount = ApolloModernChatUnreadBadgeCount();
    self.chatUnreadBadge.hidden = unreadCount <= 0;
    if (unreadCount > 0) {
        self.chatUnreadBadge.text = unreadCount > 99 ? @"99+"
            : [NSString stringWithFormat:@"%ld", (long)unreadCount];
    }
    NSString *unreadValue = unreadCount > 0
        ? [NSString stringWithFormat:@"%ld unread", (long)unreadCount] : nil;

    UIColor *accent = ApolloModernChatThemeColor(traits, @"accent");
    UIColor *selectedText = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    self.backgroundColor = ApolloModernChatThemeColor(traits, @"primary");
    self.chatUnreadBadge.backgroundColor = UIColor.systemRedColor;
    self.chatUnreadBadge.textColor = UIColor.whiteColor;

    if (self.segmentedControl) {
        // Native Liquid Glass chrome; only the tint comes from the theme.
        // Appearance writes rebuild the segments, so only perform them when a
        // color genuinely changed (theme edit, light/dark flip) — never on the
        // routine status refreshes that follow every tap and unread update.
        UIColor *text = ApolloModernChatThemeColor(traits, @"text");
        BOOL colorsChanged = ![self.lastAppliedAccent isEqual:accent] ||
            ![self.lastAppliedText isEqual:text] ||
            ![self.lastAppliedSelectedText isEqual:selectedText];
        if (colorsChanged) {
            self.lastAppliedAccent = accent;
            self.lastAppliedText = text;
            self.lastAppliedSelectedText = selectedText;
            self.segmentedControl.selectedSegmentTintColor = accent;
            [self.segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: text}
                                                 forState:UIControlStateNormal];
            [self.segmentedControl setTitleTextAttributes:@{NSForegroundColorAttributeName: selectedText}
                                                 forState:UIControlStateSelected];
        }
        self.segmentedControl.accessibilityValue = unreadValue;
        [self setNeedsLayout];
        return;
    }

    self.chatButton.accessibilityValue = unreadValue;
    UIColor *raised = ApolloModernChatThemeColor(traits, @"tertiary");
    UIColor *separator = ApolloModernChatThemeColor(traits, @"separator");
    UIColor *secondaryText = ApolloModernChatThemeColor(traits, @"secondaryText");
    self.containerView.backgroundColor = raised;
    self.containerView.layer.borderColor = [separator resolvedColorWithTraitCollection:traits].CGColor;
    self.selectionView.backgroundColor = accent;
    [self.notificationsButton setTitleColor:self.selectedMode == ApolloInboxModeNotifications ? selectedText : secondaryText
                                    forState:UIControlStateNormal];
    [self.chatButton setTitleColor:self.selectedMode == ApolloInboxModeChat ? selectedText : secondaryText
                          forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_refreshForTraits:self.traitCollection];
}

@end

// Secondary Chat navigation mirrors the compact layout in Reddit's current
// Inbox while retaining Apollo's palette and typography. The selected item is
// a soft pill rather than another full-width segmented control, keeping the
// hierarchy clear: Notifications / Chat first, then the three Chat sections.
@interface ApolloInboxChatSectionSwitcherView : UIControl
@property (nonatomic, strong) UIView *selectionView;
@property (nonatomic, strong) UIView *bottomSeparator;
@property (nonatomic, strong) UIButton *messagesButton;
@property (nonatomic, strong) UIButton *requestsButton;
@property (nonatomic, strong) UIButton *threadsButton;
@property (nonatomic, strong) UILabel *requestsBadge;
@property (nonatomic, assign) ApolloModernChatInboxSection selectedSection;
- (UIButton *)apollo_buttonWithTitle:(NSString *)title action:(SEL)action;
- (void)apollo_setSelectedSection:(ApolloModernChatInboxSection)section animated:(BOOL)animated;
- (void)apollo_refreshForTraits:(UITraitCollection *)traits;
@end

@implementation ApolloInboxChatSectionSwitcherView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.selectionView = [UIView new];
    self.selectionView.userInteractionEnabled = NO;
    self.selectionView.layer.cornerRadius = 18.0;
    [self addSubview:self.selectionView];

    self.messagesButton = [self apollo_buttonWithTitle:@"Messages"
                                                action:@selector(apollo_buttonTapped:)];
    self.requestsButton = [self apollo_buttonWithTitle:@"Requests"
                                                action:@selector(apollo_buttonTapped:)];
    self.threadsButton = [self apollo_buttonWithTitle:@"Threads"
                                              action:@selector(apollo_buttonTapped:)];
    [self addSubview:self.messagesButton];
    [self addSubview:self.requestsButton];
    [self addSubview:self.threadsButton];

    self.requestsBadge = [UILabel new];
    self.requestsBadge.text = @"1";
    self.requestsBadge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    self.requestsBadge.textAlignment = NSTextAlignmentCenter;
    self.requestsBadge.layer.cornerRadius = 9.0;
    self.requestsBadge.clipsToBounds = YES;
    self.requestsBadge.hidden = YES;
    self.requestsBadge.userInteractionEnabled = NO;
    // Spoken via requestsButton.accessibilityValue, not as its own element.
    self.requestsBadge.isAccessibilityElement = NO;
    [self addSubview:self.requestsBadge];

    self.bottomSeparator = [UIView new];
    self.bottomSeparator.userInteractionEnabled = NO;
    [self addSubview:self.bottomSeparator];
    _selectedSection = ApolloModernChatInboxSectionMessages;
    return self;
}

- (UIButton *)apollo_buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    button.accessibilityLabel = title;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // The selected section is assigned while the view controller is still
    // loading, before Auto Layout has given this control a real size. Avoid
    // constructing negative button frames from CGRectInset at that point;
    // UIButton's internal title layout can turn those into NaN/Inf layer
    // positions on iOS 26.
    if (CGRectGetWidth(self.bounds) <= 20.0 || CGRectGetHeight(self.bounds) <= 14.0) return;
    CGRect content = CGRectInset(self.bounds, 10.0, 7.0);
    content.size.height = MIN(36.0, content.size.height);
    CGFloat width = floor(content.size.width / 3.0);
    CGRect messagesFrame = CGRectMake(content.origin.x, content.origin.y, width, content.size.height);
    CGRect requestsFrame = CGRectMake(CGRectGetMaxX(messagesFrame), content.origin.y, width, content.size.height);
    CGRect threadsFrame = CGRectMake(CGRectGetMaxX(requestsFrame), content.origin.y,
                                     CGRectGetMaxX(content) - CGRectGetMaxX(requestsFrame), content.size.height);
    self.messagesButton.frame = messagesFrame;
    self.requestsButton.frame = requestsFrame;
    self.threadsButton.frame = threadsFrame;
    switch (self.selectedSection) {
        case ApolloModernChatInboxSectionRequests:
            self.selectionView.frame = CGRectInset(requestsFrame, 3.0, 0.0);
            break;
        case ApolloModernChatInboxSectionThreads:
            self.selectionView.frame = CGRectInset(threadsFrame, 3.0, 0.0);
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            self.selectionView.frame = CGRectInset(messagesFrame, 3.0, 0.0);
            break;
    }
    CGFloat requestsBadgeWidth = 18.0;
    if (self.requestsBadge.text.length > 1) {
        CGSize textSize = [self.requestsBadge.text sizeWithAttributes:
                           @{NSFontAttributeName: self.requestsBadge.font}];
        requestsBadgeWidth = MAX(18.0, ceil(textSize.width) + 10.0);
    }
    self.requestsBadge.frame = CGRectMake(CGRectGetMidX(requestsFrame) + 34.0,
                                          CGRectGetMidY(requestsFrame) - 15.0, requestsBadgeWidth, 18.0);
    self.bottomSeparator.frame = CGRectMake(0, CGRectGetHeight(self.bounds) - 0.5,
                                            CGRectGetWidth(self.bounds), 0.5);
}

- (void)apollo_buttonTapped:(UIButton *)sender {
    ApolloModernChatInboxSection section = ApolloModernChatInboxSectionMessages;
    if (sender == self.requestsButton) section = ApolloModernChatInboxSectionRequests;
    else if (sender == self.threadsButton) section = ApolloModernChatInboxSectionThreads;
    [self apollo_setSelectedSection:section animated:YES];
    // Send even for a re-selected tab so tapping Messages while inside a room
    // returns to the Messages list, like a normal tab controller.
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)apollo_setSelectedSection:(ApolloModernChatInboxSection)section animated:(BOOL)animated {
    _selectedSection = section;
    void (^changes)(void) = ^{
        [self setNeedsLayout];
        if (CGRectGetWidth(self.bounds) > 20.0 && CGRectGetHeight(self.bounds) > 14.0) {
            [self layoutIfNeeded];
        }
    };
    if (animated && self.window) {
        [UIView animateWithDuration:0.18 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:changes completion:nil];
    } else {
        changes();
    }
    [self apollo_refreshForTraits:self.traitCollection];
}

- (void)apollo_refreshForTraits:(UITraitCollection *)traits {
    NSDictionary *status = ApolloModernChatCachedStatus();
    BOOL hasRequests = [status[@"hasRequests"] boolValue];
    // Exact count comes from the background poller; the webview DOM scrape
    // only knows a boolean, so keep 1 as the marker-only fallback.
    NSInteger requestsCount = MAX(0, [status[@"requestsCount"] integerValue]);
    if (hasRequests && requestsCount == 0) requestsCount = 1;
    self.requestsBadge.hidden = !hasRequests;
    self.requestsBadge.text = requestsCount > 99 ? @"99+"
        : [NSString stringWithFormat:@"%ld", (long)MAX(1, requestsCount)];
    self.requestsButton.accessibilityValue = hasRequests
        ? [NSString stringWithFormat:@"%ld new", (long)requestsCount] : nil;

    UIColor *accent = ApolloModernChatThemeColor(traits, @"accent");
    UIColor *primary = ApolloModernChatThemeColor(traits, @"primary");
    UIColor *raised = ApolloModernChatThemeColor(traits, @"tertiary");
    UIColor *secondaryText = ApolloModernChatThemeColor(traits, @"secondaryText");
    self.backgroundColor = primary;
    self.selectionView.backgroundColor = raised;
    self.bottomSeparator.backgroundColor = ApolloModernChatThemeColor(traits, @"separator");
    [self.messagesButton setTitleColor:self.selectedSection == ApolloModernChatInboxSectionMessages ? accent : secondaryText
                               forState:UIControlStateNormal];
    [self.requestsButton setTitleColor:self.selectedSection == ApolloModernChatInboxSectionRequests ? accent : secondaryText
                               forState:UIControlStateNormal];
    [self.threadsButton setTitleColor:self.selectedSection == ApolloModernChatInboxSectionThreads ? accent : secondaryText
                              forState:UIControlStateNormal];
    self.requestsBadge.backgroundColor = UIColor.systemRedColor;
    self.requestsBadge.textColor = UIColor.whiteColor;
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_refreshForTraits:self.traitCollection];
}

@end

@interface ApolloInboxChatHubViewController : UIViewController
@property (nonatomic, strong) ApolloInboxModeSwitcherView *modeSwitcher;
@property (nonatomic, strong) ApolloInboxChatSectionSwitcherView *sectionSwitcher;
@property (nonatomic, strong) UIView *contentContainerView;
@property (nonatomic, strong) UIViewController *chatController;
@property (nonatomic, weak) UIViewController *inboxHostController;
@property (nonatomic, strong) NSLayoutConstraint *modeSwitcherTopConstraint;
- (void)apollo_refreshTheme;
- (void)apollo_showSection:(ApolloModernChatInboxSection)section animated:(BOOL)animated;
- (void)apollo_alignModeSwitcherWithHostSwitcher:(ApolloInboxModeSwitcherView *)hostSwitcher;
@end

static ApolloInboxChatHubViewController *ApolloEnsureInboxChatHub(UIViewController *host);
static void ApolloSetInboxChatHubVisible(UIViewController *host, BOOL visible, BOOL animated);
static void ApolloDismantleInboxChatHub(UIViewController *host, NSString *reason);
static void ApolloInboxWireModePanPrecedence(UIViewController *controller, UIPanGestureRecognizer *modePan);
static BOOL ApolloInboxBeginModeTransition(UIViewController *host, BOOL toChat);
static void ApolloInboxUpdateModeTransition(UIViewController *host, CGFloat progress);
static void ApolloInboxFinishModeTransition(UIViewController *host, BOOL commit, CGFloat velocity);

// What the in-flight swipe is doing. One drag at a time, on one singleton pan,
// so this state is a file static rather than per-host bookkeeping.
typedef NS_ENUM(NSUInteger, ApolloInboxSwipeKind) {
    ApolloInboxSwipeKindNone = 0,
    ApolloInboxSwipeKindMode,               // Notifications <-> Chat, as sibling pages
    ApolloInboxSwipeKindConversationBack,   // out of an open conversation, as a pop
};
static ApolloInboxSwipeKind sInboxSwipeKind = ApolloInboxSwipeKindNone;
static BOOL sInboxSwipeInteractive = NO;    // NO = fall back to the plain switch at release
static BOOL sInboxSwipeToChat = NO;
static CGFloat sInboxSwipeProgress = 0.0;
// Bumped by every drag that starts. A settle animation from an earlier drag
// carries its own value and leaves the shared state alone if a newer drag has
// already claimed these views.
static NSUInteger sInboxSwipeGeneration = 0;
static __weak ApolloInboxChatHubViewController *sInboxSwipeHub = nil;
static __weak UITableView *sInboxSwipeTableView = nil;
// While a drag owns the two pages, ApolloSetInboxChatHubVisible must not run
// its cross-fade or hide the hub: the drag's own animation IS the transition,
// and its completion applies the settled alpha/hidden state.
static BOOL sInboxModeTransitionActive = NO;

// The inbox mode-pan (both tab-switch directions) is a PROCESS SINGLETON,
// not a per-host recognizer. Apollo's full-width back/forward pans and the
// interactive pop live on the navigation controller's UILayoutContainerView
// and are shared by every screen in that stack, and
// requireGestureRecognizerToFail: is permanent — UIKit has no API to remove
// a requirement. Minting a fresh pan per install would re-wire those shared
// recognizers against each new pan, accumulating stale requirements (each
// pointing at a since-dead pan) for the life of the session. One immortal
// pan keeps every shared recognizer wired at most once, ever: the pan
// migrates to whichever Inbox host is installing (addGestureRecognizer:
// moves it between views), and while it is detached — feature off, host
// gone — it can never begin, so its requirements are vacuously satisfied
// and every other screen's gestures behave stock.
static UIPanGestureRecognizer *sInboxModePan;
// Zeroing-weak host back-pointer, read from gesture-delegate callbacks. An
// ASSIGN association here would dangle if the host deallocs while UIKit
// still holds the pan across a touch (the #921/#876/#870 crash shape).
static __weak UIViewController *sInboxModePanHost;
// Recognizers already wired to require the mode-pan's failure. Weak members
// (dead recognizers fall out on their own); static so the dedupe spans
// switcher reinstalls and host controller lifetimes.
static NSHashTable *sInboxModePanWired;

@implementation ApolloInboxChatHubViewController

- (instancetype)init {
    self = [super init];
    if (self) self.hidesBottomBarWhenPushed = NO;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chat";
    self.view.clipsToBounds = YES;

    self.modeSwitcher = [ApolloInboxModeSwitcherView new];
    self.modeSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeSwitcher apollo_setSelectedMode:ApolloInboxModeChat animated:NO];
    [self.modeSwitcher addTarget:self action:@selector(apollo_modeChanged:)
                forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeSwitcher];

    self.sectionSwitcher = [ApolloInboxChatSectionSwitcherView new];
    self.sectionSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sectionSwitcher apollo_setSelectedSection:ApolloModernChatInboxSectionMessages animated:NO];
    [self.sectionSwitcher addTarget:self action:@selector(apollo_sectionChanged:)
                   forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.sectionSwitcher];

    self.contentContainerView = [UIView new];
    self.contentContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainerView.clipsToBounds = YES;
    [self.view addSubview:self.contentContainerView];

    self.modeSwitcherTopConstraint = [self.modeSwitcher.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor];
    [NSLayoutConstraint activateConstraints:@[
        // Apollo's Inbox view extends beneath its translucent navigation bar.
        // Start below the host's full top safe area so both rows sit beneath
        // the Inbox title/back button instead of showing through that bar.
        self.modeSwitcherTopConstraint,
        [self.modeSwitcher.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.modeSwitcher.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modeSwitcher.heightAnchor constraintEqualToConstant:60.0],
        [self.sectionSwitcher.topAnchor constraintEqualToAnchor:self.modeSwitcher.bottomAnchor],
        [self.sectionSwitcher.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sectionSwitcher.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sectionSwitcher.heightAnchor constraintEqualToConstant:50.0],
        [self.contentContainerView.topAnchor constraintEqualToAnchor:self.sectionSwitcher.bottomAnchor],
        [self.contentContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.chatController = ApolloCreateEmbeddedModernChatViewController(
        ApolloModernChatInboxSectionMessages);
    [self addChildViewController:self.chatController];
    self.chatController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainerView addSubview:self.chatController.view];
    [NSLayoutConstraint activateConstraints:@[
        [self.chatController.view.topAnchor constraintEqualToAnchor:self.contentContainerView.topAnchor],
        [self.chatController.view.leadingAnchor constraintEqualToAnchor:self.contentContainerView.leadingAnchor],
        [self.chatController.view.trailingAnchor constraintEqualToAnchor:self.contentContainerView.trailingAnchor],
        [self.chatController.view.bottomAnchor constraintEqualToAnchor:self.contentContainerView.bottomAnchor],
    ]];
    [self.chatController didMoveToParentViewController:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_chatStatusChanged:)
                                                 name:ApolloModernChatStatusDidChangeNotification
                                               object:nil];
    [self apollo_refreshTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.modeSwitcher apollo_setSelectedMode:ApolloInboxModeChat animated:NO];
    [self apollo_refreshTheme];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_refreshTheme];
}

- (void)apollo_refreshTheme {
    UIColor *background = ApolloModernChatThemeColor(self.traitCollection, @"primary");
    self.view.backgroundColor = background;
    self.contentContainerView.backgroundColor = background;
    [self.modeSwitcher apollo_refreshForTraits:self.traitCollection];
    [self.sectionSwitcher apollo_refreshForTraits:self.traitCollection];
}

- (void)apollo_modeChanged:(ApolloInboxModeSwitcherView *)sender {
    if (sender.selectedMode != ApolloInboxModeNotifications) return;
    ChatsFilterLog(@"Chat hub returning to Notifications");
    if (self.inboxHostController) {
        ApolloSetInboxChatHubVisible(self.inboxHostController, NO, YES);
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)apollo_sectionChanged:(ApolloInboxChatSectionSwitcherView *)sender {
    [self apollo_showSection:sender.selectedSection animated:YES];
}

- (void)apollo_showSection:(ApolloModernChatInboxSection)section animated:(BOOL)animated {
    [self.sectionSwitcher apollo_setSelectedSection:section animated:animated];
    ApolloModernChatControllerShowInboxSection(self.chatController, section);
    NSString *name = section == ApolloModernChatInboxSectionRequests ? @"Requests" :
        (section == ApolloModernChatInboxSectionThreads ? @"Threads" : @"Messages");
    ChatsFilterLog(@"Chat hub selected %@", name);
}

- (void)apollo_alignModeSwitcherWithHostSwitcher:(ApolloInboxModeSwitcherView *)hostSwitcher {
    if (!hostSwitcher || !self.modeSwitcherTopConstraint) return;
    // Notifications owns a sticky sibling switcher. Match its current on-screen
    // Y position before cross-fading to Chat. It normally equals the safe-area
    // top, but measuring the live view keeps rotations and custom navigation
    // heights exact without allowing either control under the Inbox title.
    [self.inboxHostController.view layoutIfNeeded];
    [self.view layoutIfNeeded];
    CGRect hostFrame = [hostSwitcher convertRect:hostSwitcher.bounds toView:self.view];
    CGFloat safeAreaTop = CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame);
    CGFloat targetConstant = MAX(0.0, CGRectGetMinY(hostFrame) - safeAreaTop);
    if (fabs(self.modeSwitcherTopConstraint.constant - targetConstant) < 0.5) return;
    self.modeSwitcherTopConstraint.constant = targetConstant;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    ChatsFilterLog(@"aligned Chat switcher to scrolled Notifications header at %.1fpt",
                   CGRectGetMinY(hostFrame));
}

- (void)apollo_chatStatusChanged:(NSNotification *)notification {
    [self.modeSwitcher apollo_refreshForTraits:self.traitCollection];
    [self.sectionSwitcher apollo_refreshForTraits:self.traitCollection];
}

@end

// Notifications and Chat are sibling modes of Inbox, so changing between them
// must not push another view controller. Keep a single Chat child alive above
// Apollo's notification table and cross-fade it in place. The notification list
// underneath never leaves the hierarchy, preserving its exact scroll position
// and avoiding the horizontal navigation/reload effect shown in the recording.
static ApolloInboxChatHubViewController *ApolloEnsureInboxChatHub(UIViewController *host) {
    if (!host || !ApolloModernChatShouldOpen()) return nil;
    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(host, &kInboxAllChatHubKey);
    // A retained hub is only reusable while it still represents the active
    // account's live web session. After an account switch (or a cookie
    // rotation from a re-harvest) the embedded WebKit client would keep
    // showing — and composing as — the PREVIOUS identity, so replace it.
    if (hub && !ApolloModernChatControllerSessionIsCurrent(hub.chatController)) {
        ApolloDismantleInboxChatHub(host, @"stale session identity");
        hub = nil;
    }
    if (hub) return hub;

    hub = [ApolloInboxChatHubViewController new];
    hub.inboxHostController = host;
    [host addChildViewController:hub];
    // Accessing the view here intentionally starts the embedded authenticated
    // Chat client while Notifications remains visible. A later tap only
    // cross-fades this already-hydrated child instead of creating WebKit on the
    // critical interaction path.
    hub.view.frame = host.view.bounds;
    hub.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    hub.view.alpha = 0.0;
    hub.view.hidden = YES;
    hub.view.userInteractionEnabled = NO;
    [host.view addSubview:hub.view];
    [hub didMoveToParentViewController:host];
    objc_setAssociatedObject(host, &kInboxAllChatHubKey, hub, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ChatsFilterLog(@"created and quietly preloaded persistent in-place Chat hub");
    return hub;
}

// The singleton mode-pan, but only while `host` is the controller it is
// currently attached to and targeting — nil for any other (stale) host.
static UIPanGestureRecognizer *ApolloInboxModePanForHost(UIViewController *host) {
    if (!sInboxModePan || !host) return nil;
    if (sInboxModePanHost != host) return nil;
    if (sInboxModePan.view != host.viewIfLoaded) return nil;
    return sInboxModePan;
}

static void ApolloSetInboxChatHubVisible(UIViewController *host, BOOL visible, BOOL animated) {
    if (!host) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloSetInboxChatHubVisible(host, visible, animated);
        });
        return;
    }

    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(host, &kInboxAllChatHubKey);
    // Never reveal a hub seeded for a different account/session — dismantle
    // and let the ensure below rebuild one for the CURRENT identity. (The
    // dismantle's internal hide call cannot recurse here: it passes
    // visible=NO, which skips this branch.)
    if (visible && hub && !ApolloModernChatControllerSessionIsCurrent(hub.chatController)) {
        ApolloDismantleInboxChatHub(host, @"stale session at reveal");
        hub = nil;
    }
    if (visible && !hub) hub = ApolloEnsureInboxChatHub(host);
    if (!hub) return;

    // The hub cross-fades its child without UIKit appearance callbacks. Tell
    // the route-aware web controller explicitly so a hidden Chat room cannot
    // leave the shared Inbox tab bar hidden over Notifications.
    ApolloModernChatControllerSetInboxVisible(hub.chatController, visible);

    BOOL wasVisible = [objc_getAssociatedObject(host, &kInboxAllChatHubVisibleKey) boolValue];
    objc_setAssociatedObject(host, &kInboxAllChatHubVisibleKey, @(visible), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloInboxModeSwitcherView *notificationsSwitcher = objc_getAssociatedObject(host, &kInboxAllModeSwitcherKey);
    // With a host switcher present there is exactly ONE visible mode control:
    // the host's, kept above the hub in both modes. Cross-fading the hub's own
    // copy over it blended a static thumb into the tapped control's in-flight
    // Liquid Glass morph (a visible double exposure / saturation pop at the
    // end of every switch). The hub keeps its switcher only when presented
    // standalone, where no host switcher exists.
    hub.modeSwitcher.hidden = (notificationsSwitcher != nil);
    [notificationsSwitcher apollo_setSelectedMode:visible ? ApolloInboxModeChat : ApolloInboxModeNotifications
                                          animated:animated];
    [hub.modeSwitcher apollo_setSelectedMode:visible ? ApolloInboxModeChat : ApolloInboxModeNotifications
                                     animated:animated];

    NSArray<UIBarButtonItem *> *savedRightItems = objc_getAssociatedObject(host, &kInboxAllOriginalRightItemsKey);
    if (!savedRightItems) {
        savedRightItems = host.navigationItem.rightBarButtonItems ?: @[];
        objc_setAssociatedObject(host, &kInboxAllOriginalRightItemsKey,
                                 [savedRightItems copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Stripping the right buttons must not let the Liquid Glass recenter
    // re-balance the "Inbox" title against an empty trailing side — the title
    // visibly slid toward screen center on every Notifications -> Chat switch
    // and back again on the return. Hold the trailing reservation BEFORE the
    // strip (so a recenter pass mid-removal already holds the old edge) and
    // release it only AFTER the restore (so no pass between the two sees a
    // bare bar). No-op off-glass and under the pre-26 nav bar.
    if (visible) ApolloNavItemSetTrailingReservationHold(host.navigationItem, YES);
    [host.navigationItem setRightBarButtonItems:visible ? nil : (savedRightItems.count ? savedRightItems : nil)
                                       animated:animated];
    if (!visible) ApolloNavItemSetTrailingReservationHold(host.navigationItem, NO);

    if (visible) {
        // The install-time wiring runs before the host view joins the
        // navigation container, so Apollo's full-width back/forward pans
        // (they live on the nav controller's UILayoutContainerView) are only
        // reachable now — re-wire so they yield to the mode-pan.
        ApolloInboxWireModePanPrecedence(host, ApolloInboxModePanForHost(host));
        // Align the persistent Chat overlay to the live sticky Notifications
        // switcher before making it visible.
        [hub apollo_alignModeSwitcherWithHostSwitcher:notificationsSwitcher];
        hub.view.hidden = NO;
        hub.view.userInteractionEnabled = YES;
        [host.view bringSubviewToFront:hub.view];
        // Keep the single live mode control (and its opaque backdrop strip)
        // above the hub so both mode switches happen on one control with an
        // uninterrupted native thumb animation.
        UIView *navigationBackdrop = objc_getAssociatedObject(host, &kInboxAllNavigationBackdropKey);
        if (navigationBackdrop.superview == host.view) {
            [host.view bringSubviewToFront:navigationBackdrop];
        }
        if (notificationsSwitcher.superview == host.view) {
            [host.view bringSubviewToFront:notificationsSwitcher];
        }
        // Every deliberate Notifications -> Chat switch starts at Messages.
        // A quietly-preloaded hub already starts there, so do not restart its
        // in-flight readiness/filter work just because it became visible.
        if (!wasVisible &&
            hub.sectionSwitcher.selectedSection != ApolloModernChatInboxSectionMessages) {
            [hub apollo_showSection:ApolloModernChatInboxSectionMessages animated:NO];
        }
        [hub apollo_refreshTheme];
        // The WebKit list is quietly hydrated while another tab may still be
        // selected, so its first layout cannot measure Apollo's floating tab
        // bar. Recalculate the inner scroll allowance once Inbox Chat is
        // actually on-screen.
        ApolloModernChatControllerRefreshEmbeddedLayout(hub.chatController);
    } else {
        hub.view.userInteractionEnabled = NO;
    }

    void (^changes)(void) = ^{
        hub.view.alpha = visible ? 1.0 : 0.0;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        BOOL stillVisible = [objc_getAssociatedObject(host, &kInboxAllChatHubVisibleKey) boolValue];
        if (!stillVisible) hub.view.hidden = YES;
    };
    if (sInboxModeTransitionActive) {
        // A swipe is holding both pages in place mid-drag. Everything above
        // (bar items, the mode control, tab-bar ownership) still applies so
        // the chrome settles with the motion, but the hub's alpha and hidden
        // flag belong to the drag until it finishes.
    } else if (animated && host.view.window) {
        // The single host-owned switcher stays above the fading hub, so the
        // content cross-fade can run immediately alongside its native thumb
        // animation — exactly like a stock segmented control driving a
        // content switch.
        [UIView animateWithDuration:0.20
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:changes
                         completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

// Full teardown of the persistent Chat hub: used when the modern Chat setting
// turns off, and whenever the retained hub no longer matches the active
// account's session. Releasing the hub deallocs the embedded web controller,
// whose dealloc invalidates its 20s status timer and observers — the WebKit
// client, injected scripts, and private data store all go with it.
static void ApolloDismantleInboxChatHub(UIViewController *host, NSString *reason) {
    if (!host) return;
    // Same main-thread deferral as ApolloSetInboxChatHubVisible. Without it,
    // an off-main caller (Apollo posts the account-change notification from
    // wherever) would tear the hub down off-main while the hide it just
    // requested is still queued for main — the deferred hide then finds the
    // association already cleared, no-ops, and the stripped right bar items
    // (and the reservation hold) are never restored.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloDismantleInboxChatHub(host, reason); });
        return;
    }
    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(host, &kInboxAllChatHubKey);
    if (!hub) return;
    // Hiding first restores the host's saved right bar items, hands the
    // shared tab bar back to Notifications, and resets the visible flag —
    // the hide path has no ShouldOpen gate, so this works mid-disable too.
    ApolloSetInboxChatHubVisible(host, NO, NO);
    [hub willMoveToParentViewController:nil];
    [hub.view removeFromSuperview];
    [hub removeFromParentViewController];
    objc_setAssociatedObject(host, &kInboxAllChatHubKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(host, &kInboxAllChatHubVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The restored right bar items are live on the navigation item again;
    // clear the stash so a later re-enable captures a fresh copy.
    objc_setAssociatedObject(host, &kInboxAllOriginalRightItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The hide above already released the trailing reservation hold, but keep
    // dismantle self-sufficient: the hold must never outlive the hub on this
    // navigation item, whatever path led here.
    ApolloNavItemSetTrailingReservationHold(host.navigationItem, NO);
    ChatsFilterLog(@"dismantled Inbox chat hub (%@)", reason ?: @"unknown");
}

static BOOL ApolloInboxControllerIsAll(id controller) {
    Ivar ivar = class_getInstanceVariable([controller class], "inboxType");
    if (ivar) {
        uint8_t raw = *((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
        if (raw == 0) return YES; // Apollo.InboxType.inbox is the first enum case.
    }
    return [((UIViewController *)controller).title isEqualToString:@"Inbox"];
}

static UITableView *ApolloInboxControllerTableView(id controller) {
    Ivar ivar = class_getInstanceVariable([controller class], "tableNode");
    id tableNode = ivar ? object_getIvar(controller, ivar) : nil;
    if ([tableNode respondsToSelector:@selector(view)]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        if ([view isKindOfClass:[UITableView class]]) return view;
    }
    return nil;
}

static UIRefreshControl *ApolloInboxRefreshControl(UITableView *tableView) {
    UIRefreshControl *refreshControl = tableView.refreshControl;
    if (refreshControl) return refreshControl;
    for (UIView *subview in tableView.subviews) {
        if ([subview isKindOfClass:[UIRefreshControl class]]) return (UIRefreshControl *)subview;
    }
    return nil;
}

// The opaque switcher sits exactly over the band where UIKit parks the
// native inbox pull-to-refresh spinner (right below the navigation bar,
// same spot as every other Apollo list). Every geometry-level workaround
// fails here: UIKit rewrites the control's frame each pull tick (cancelling
// view transforms), a layer offset detaches the spinner from the reveal
// choreography, and both Apollo's layout and UIKit's refresh-hold rewrite
// contentInset (so inset re-anchoring either gets stomped or ratchets).
// Move the CHROME instead: while the list is overscrolled — pulling or
// holding a refresh — the switcher fades out and the completely untouched
// native choreography (progressive reveal, spin, settle) plays in its
// normal spot; the switcher fades back in when the list returns to rest.
// The table carries a flag plus a reference to its switcher so this scroll
// hook can drive the fade with one associated-object read per frame.
// MARK: - Inbox mode-pan precedence
//
// Apollo pops screens with full-width swipe-back PANS on the navigation
// container (plus the system interactive pop), and offers the mirrored
// full-width FORWARD pan to re-enter the screen you swiped back from. Inside
// the Inbox those whole-screen gestures belong only to its outermost levels:
// back means "previous screen" only from Notifications (the first tab, with
// nothing open above it) and forward only from Chat (the last tab). Everything
// in between — the tab switch, and the step out of an open conversation — is
// the tab-switch pan installed in ApolloInstallInboxModeSwitcher, so every pan
// on the host's ancestor chain is wired here to REQUIRE the mode-pan's failure:
// when the mode-pan begins (a horizontal drag toward the other tab — see the
// shared delegate's gestureRecognizerShouldBegin:), Apollo's back/forward
// pans and the interactive pop sit the touch out; in every other situation
// the mode-pan fails on the spot and they behave exactly as stock. Scroll
// views' own pans are spared (the delegate already recognizes simultaneously
// with them). The chat hub's WKWebView edge gestures (history back/forward)
// are wired too, so an edge grab returns to the chat list or Notifications
// instead of also walking web history. Inside a conversation the same pan owns
// the back direction as well, and its handler climbs one level of Reddit's
// chat hierarchy (conversation -> list) rather than switching tabs — without
// it, Apollo's stock pop skipped both levels and left Inbox entirely. A pan —
// not a discrete swipe recognizer — because WebKit's deferring gates release
// held recognizers with the touch history accumulated so far, which lets a pan
// begin late but leaves a discrete swipe dead (verified with real HID swipes
// over the hub).
static void ApolloInboxWireModePanPrecedence(UIViewController *controller, UIPanGestureRecognizer *modePan) {
    // Only wire while the pan actually belongs to this controller — never
    // point shared recognizers at the pan on a stale host's behalf.
    if (!modePan || modePan != ApolloInboxModePanForHost(controller)) return;
    if (!sInboxModePanWired) sInboxModePanWired = [NSHashTable weakObjectsHashTable];
    NSHashTable *wired = sInboxModePanWired;
    UIGestureRecognizer *pop = controller.navigationController.interactivePopGestureRecognizer;
    if (pop && ![wired containsObject:pop]) {
        [pop requireGestureRecognizerToFail:modePan];
        [wired addObject:pop];
    }
    for (UIView *view = controller.viewIfLoaded; view; view = view.superview) {
        UIGestureRecognizer *scrollPan =
            [view isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)view).panGestureRecognizer : nil;
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (recognizer == modePan || recognizer == scrollPan || recognizer == pop) continue;
            if ([wired containsObject:recognizer]) continue;
            if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            [recognizer requireGestureRecognizerToFail:modePan];
            [wired addObject:recognizer];
        }
    }
    // WebKit re-creates content views (and their edge recognizers) across
    // navigations; this wiring re-runs on every install pass and every
    // Chat reveal, which keeps new ones covered.
    // NOTE: ApolloFeedGalleryCarousel's wiring walk deliberately SKIPS
    // UIScreenEdgePanGestureRecognizers (a permanent requirement there would
    // block navigation for every carousel on screen). The trade-off flips
    // here because the required pan is the process singleton: detached or
    // instantly-failed, it satisfies the requirement immediately. Read both
    // rationales before "harmonizing" either walk.
    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(controller, &kInboxAllChatHubKey);
    UIView *hubView = hub.viewIfLoaded;
    if (hubView) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:hubView];
        for (NSUInteger index = 0; index < queue.count; index++) {
            UIView *view = queue[index];
            for (UIView *subview in view.subviews) [queue addObject:subview];
            for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
                if (![recognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) continue;
                if ([wired containsObject:recognizer]) continue;
                [recognizer requireGestureRecognizerToFail:modePan];
                [wired addObject:recognizer];
            }
        }
    }
}

%hook ASTableView
- (void)setContentOffset:(CGPoint)contentOffset {
    %orig(contentOffset);
    if (![objc_getAssociatedObject(self, &kInboxAllSwitcherTableKey) boolValue]) return;
    ApolloInboxModeSwitcherView *switcher = objc_getAssociatedObject(self, &kInboxAllSwitcherRefKey);
    if (!switcher) return;
    // 8pt of grace keeps ordinary edge-bounce jitter from flickering the bar.
    BOOL overscrolled = contentOffset.y < -((UIScrollView *)self).adjustedContentInset.top - 8.0;
    BOOL visible = switcher.alpha > 0.5;   // UIView animations update the model value immediately
    BOOL showPending = [objc_getAssociatedObject(self, &kInboxAllShowPendingKey) boolValue];

    if (overscrolled) {
        if (!visible && !showPending) return;
        // Invalidate any queued fade-in, then hide immediately.
        NSInteger generation = [objc_getAssociatedObject(self, &kInboxAllFadeGenerationKey) integerValue] + 1;
        objc_setAssociatedObject(self, &kInboxAllFadeGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kInboxAllShowPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (visible) {
            [UIView animateWithDuration:0.15
                                  delay:0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{ switcher.alpha = 0.0; }
                             completion:nil];
        }
        return;
    }

    if (visible || showPending) return;
    // Debounce the return: Apollo's post-refresh content reload briefly
    // re-holds the list a moment after the settle starts, so an immediate
    // fade-in made the bar blink in, out, and in again. Fade back only once
    // the list has stayed at rest for a beat; a new overscroll in the
    // window invalidates the queued show via the generation counter.
    NSInteger generation = [objc_getAssociatedObject(self, &kInboxAllFadeGenerationKey) integerValue] + 1;
    objc_setAssociatedObject(self, &kInboxAllFadeGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kInboxAllShowPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITableView *weakTable = (UITableView *)self;
    __weak ApolloInboxModeSwitcherView *weakSwitcher = switcher;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UITableView *table = weakTable;
        ApolloInboxModeSwitcherView *bar = weakSwitcher;
        if (!table || !bar) return;
        if ([objc_getAssociatedObject(table, &kInboxAllFadeGenerationKey) integerValue] != generation) return;
        objc_setAssociatedObject(table, &kInboxAllShowPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![objc_getAssociatedObject(table, &kInboxAllSwitcherTableKey) boolValue]) return;
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ bar.alpha = 1.0; }
                         completion:nil];
    });
}
%end

// Target object for the refresh control's trigger event; UIControl holds its
// targets weakly, so the singleton lives in the dispatch_once static below.
@interface ApolloInboxRefreshFeedback : NSObject
- (void)apollo_inboxRefreshTriggered:(UIRefreshControl *)sender;
@end
@implementation ApolloInboxRefreshFeedback
- (void)apollo_inboxRefreshTriggered:(UIRefreshControl *)sender {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}
@end

// The native inbox control fires no trigger haptic of its own; add the same
// light impact the tweak uses elsewhere, at the moment the refresh arms.
static void ApolloInboxEnsureRefreshHaptic(UITableView *tableView) {
    UIRefreshControl *refreshControl = ApolloInboxRefreshControl(tableView);
    if (!refreshControl) return;
    if ([objc_getAssociatedObject(refreshControl, &kInboxRefreshHapticKey) boolValue]) return;
    static ApolloInboxRefreshFeedback *feedback;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ feedback = [ApolloInboxRefreshFeedback new]; });
    [refreshControl addTarget:feedback
                       action:@selector(apollo_inboxRefreshTriggered:)
             forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(refreshControl, &kInboxRefreshHapticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Interactive mode transition
//
// Notifications and Chat are sibling tabs, so a swipe between them moves both
// pages together like a paging scroll view — the finger drags the incoming
// page in and the outgoing one out at the same rate, and letting go short of
// the commit point slides them back. (Tapping the mode control keeps the
// cross-fade it was tuned for: a tap has no position to track.) The pages are
// the notification table and the Chat hub's own view, both full-bounds
// siblings under the fixed mode control and its navigation backdrop, so the
// whole transition is two transforms.
static BOOL ApolloInboxBeginModeTransition(UIViewController *host, BOOL toChat) {
    if (!host || CGRectGetWidth(host.view.bounds) <= 0.0) return NO;
    ApolloInboxChatHubViewController *hub = toChat
        ? ApolloEnsureInboxChatHub(host)
        : objc_getAssociatedObject(host, &kInboxAllChatHubKey);
    UITableView *tableView = ApolloInboxControllerTableView(host);
    if (!hub || !hub.viewIfLoaded || !tableView) return NO;
    sInboxSwipeHub = hub;
    sInboxSwipeTableView = tableView;
    sInboxSwipeToChat = toChat;
    sInboxSwipeGeneration += 1;
    sInboxModeTransitionActive = YES;
    // Grabbing the pages again mid-settle hands them straight back to the
    // finger instead of letting the old animation keep driving them.
    [hub.view.layer removeAllAnimations];
    [tableView.layer removeAllAnimations];
    // Reveal the incoming page off-screen: it is only "visible" in the
    // hub-state sense once the drag commits.
    hub.view.hidden = NO;
    hub.view.alpha = 1.0;
    hub.view.userInteractionEnabled = NO;
    [host.view bringSubviewToFront:hub.view];
    UIView *navigationBackdrop = objc_getAssociatedObject(host, &kInboxAllNavigationBackdropKey);
    if (navigationBackdrop.superview == host.view) {
        [host.view bringSubviewToFront:navigationBackdrop];
    }
    ApolloInboxModeSwitcherView *switcher = objc_getAssociatedObject(host, &kInboxAllModeSwitcherKey);
    if (switcher.superview == host.view) [host.view bringSubviewToFront:switcher];
    ApolloInboxUpdateModeTransition(host, 0.0);
    return YES;
}

static void ApolloInboxUpdateModeTransition(UIViewController *host, CGFloat progress) {
    ApolloInboxChatHubViewController *hub = sInboxSwipeHub;
    UITableView *tableView = sInboxSwipeTableView;
    if (!hub || !tableView) return;
    CGFloat width = CGRectGetWidth(host.view.bounds);
    if (width <= 0.0) return;
    CGFloat clamped = MAX(0.0, MIN(1.0, progress));
    sInboxSwipeProgress = clamped;
    // Mirror under RTL, where Chat sits on the physical left.
    CGFloat rtlSign = (host.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    // Chat's offset from settled, in pages; the list is always exactly one
    // page to its leading side, which is what makes them read as adjacent
    // tabs instead of one screen covering another.
    CGFloat chatOffset = sInboxSwipeToChat ? (1.0 - clamped) : clamped;
    hub.view.transform = CGAffineTransformMakeTranslation(rtlSign * chatOffset * width, 0.0);
    tableView.transform = CGAffineTransformMakeTranslation(rtlSign * (chatOffset - 1.0) * width, 0.0);
}

static void ApolloInboxFinishModeTransition(UIViewController *host, BOOL commit, CGFloat velocity) {
    ApolloInboxChatHubViewController *hub = sInboxSwipeHub;
    UITableView *tableView = sInboxSwipeTableView;
    BOOL toChat = sInboxSwipeToChat;
    NSUInteger generation = sInboxSwipeGeneration;
    if (!host || !hub || !tableView) {
        sInboxModeTransitionActive = NO;
        return;
    }
    CGFloat width = CGRectGetWidth(host.view.bounds);
    CGFloat rtlSign = (host.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    // Settled offset of the Chat page, in pages, once this drag resolves.
    CGFloat finalChatOffset = (commit == toChat) ? 0.0 : 1.0;
    BOOL finalVisible = commit ? toChat : !toChat;
    CGFloat remaining = MAX(0.05, commit ? (1.0 - sInboxSwipeProgress) : sInboxSwipeProgress);
    // Carry the throw's speed into the settle rather than always spending the
    // same time on it.
    NSTimeInterval duration = (width > 0.0 && fabs(velocity) > 1.0)
        ? MIN(0.42, MAX(0.14, remaining * width / fabs(velocity)))
        : 0.28;
    // Settle the chrome with the motion: the mode control's thumb animates
    // across while the pages slide, and the navigation bar's buttons leave or
    // return over the same beat. The hub's own alpha/hidden state is held back
    // by sInboxModeTransitionActive until the slide lands.
    if (commit) ApolloSetInboxChatHubVisible(host, finalVisible, YES);
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        // Drive the captured pages directly rather than through the shared
        // drag state, which a newer drag may already have replaced.
        hub.view.transform =
            CGAffineTransformMakeTranslation(rtlSign * finalChatOffset * width, 0.0);
        tableView.transform =
            CGAffineTransformMakeTranslation(rtlSign * (finalChatOffset - 1.0) * width, 0.0);
    } completion:^(BOOL finished) {
        if (generation != sInboxSwipeGeneration) return;   // a newer drag owns these pages
        sInboxModeTransitionActive = NO;
        hub.view.transform = CGAffineTransformIdentity;
        tableView.transform = CGAffineTransformIdentity;
        // One owner for the settled state, cancelled drags included.
        ApolloSetInboxChatHubVisible(host, finalVisible, NO);
        sInboxSwipeHub = nil;
        sInboxSwipeTableView = nil;
    }];
}

// Delegate for the singleton inbox mode-pan. It lives on the host view above
// two scroll surfaces (the notifications ASTableView and the Chat hub's
// WKWebView scroll view), whose pan recognizers begin on ANY drag — and once a
// pan has begun, UIKit's default exclusivity blocks a still-tracking sibling
// from ever reaching Recognized (verified: synthesized began/moved/ended
// swipes through -[UIApplication sendEvent:] never fired the handler without
// this). Allowing simultaneous recognition lets the mode-pan complete
// alongside the scroll pans; the pop-gesture failure requirement set at wire
// time still takes precedence over simultaneity, so edge-pops stay exclusive.
@interface ApolloInboxSwipeGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation ApolloInboxSwipeGestureDelegate

+ (instancetype)shared {
    static ApolloInboxSwipeGestureDelegate *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ApolloInboxSwipeGestureDelegate new]; });
    return shared;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// The mode-pan must fail INSTANTLY whenever it doesn't apply — every pan on
// the host's ancestor chain (Apollo's full-width back AND forward swipes, the
// interactive pop) plus the chat web view's edge gestures wait on its
// failure, so a lingering Possible state here would add drag to the stock
// gestures. The quadrant rule: on Notifications only a leftward drag (toward
// Chat) begins, leaving rightward for back/pop; on Chat only a rightward drag
// (toward Notifications) begins, leaving leftward for Apollo's forward pan.
// That is exactly "back only on the first tab, forward only on the last".
// NOTE: translationInView: is still zero inside
// gestureRecognizerShouldBegin: — only the velocity direction is usable
// (learned on #805).
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != sInboxModePan) return YES;
    // Zeroing-weak read: once the host controller deallocs this is nil and
    // the pan simply never begins (it cannot serve a dead host).
    UIViewController *host = sInboxModePanHost;
    if (!host || !ApolloModernChatShouldOpen()) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (fabs(velocity.x) <= fabs(velocity.y)) return NO;   // decisively horizontal only
    // Mirror the whole quadrant under RTL: the segmented switcher mirrors
    // (Chat sits at the physical LEFT), so "toward Chat" is a rightward drag
    // there and the back/pop directions flip with it. In the mirrored
    // coordinate `horizontal`, negative always means "toward Chat" and
    // positive "toward Notifications / back", exactly as velocity.x does LTR.
    CGFloat rtlSign = (pan.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    CGFloat horizontal = velocity.x * rtlSign;
    if ([objc_getAssociatedObject(host, &kInboxAllChatHubVisibleKey) boolValue]) {
        if (horizontal <= 0.0) return NO;   // further toward-Chat on Chat = Apollo's forward pan
        ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(host, &kInboxAllChatHubKey);
        if (!hub) return NO;
        // Inside a conversation the same drag means one level UP Reddit's
        // chat hierarchy — back to the list the room was opened from — not
        // the tab switch, and above all not Apollo's stock pop, which used to
        // skip BOTH the room and the list and land on Boxes. Beginning here
        // is what keeps that pop (and the web view's own history edge
        // gestures, all wired to require this pan's failure) out of the
        // touch; the handler picks which of the two actions the finished drag
        // performs. A drag that starts over horizontally scrollable web
        // content still belongs to that content.
        if (ApolloModernChatControllerIsOnConversationRoute(hub.chatController) &&
            ApolloModernChatPanStartsOverHorizontalScroller(pan, hub.viewIfLoaded)) {
            return NO;
        }
        return YES;
    }
    return horizontal < 0.0;   // toward-Notifications/back on Notifications stays with back-swipe / pop
}

@end

static void ApolloInstallInboxModeSwitcher(id controller) {
    if (!ApolloInboxControllerIsAll(controller)) return;
    UITableView *tableView = ApolloInboxControllerTableView(controller);
    if (!tableView) return;

    ApolloInboxModeSwitcherView *switcher = objc_getAssociatedObject(controller, &kInboxAllModeSwitcherKey);
    UIView *navigationBackdrop = objc_getAssociatedObject(controller, &kInboxAllNavigationBackdropKey);
    if (!ApolloModernChatShouldOpen()) {
        // Turning the feature off must dismantle the retained hub too — not
        // just the native chrome — or its WebKit client, injected scripts,
        // and status timer would keep running invisibly (and a visible Chat
        // overlay would survive the setting change with the Inbox nav items
        // still stripped).
        ApolloDismantleInboxChatHub((UIViewController *)controller, @"modern Chat disabled");
        if (switcher) {
            tableView.tableHeaderView = objc_getAssociatedObject(controller, &kInboxAllOriginalHeaderKey);
            objc_setAssociatedObject(controller, &kInboxAllOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [switcher removeFromSuperview];
            objc_setAssociatedObject(controller, &kInboxAllModeSwitcherKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [navigationBackdrop removeFromSuperview];
        objc_setAssociatedObject(controller, &kInboxAllNavigationBackdropKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, &kInboxAllSwitcherTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, &kInboxAllSwitcherRefKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The mode-pan attaches only alongside the switcher. Detach it (and
        // drop its target on us) but keep the singleton itself alive: the
        // failure requirements wired on shared recognizers are permanent, and
        // a detached pan never begins, so they stay vacuously satisfied.
        UIView *staleHostView = ((UIViewController *)controller).viewIfLoaded;
        if (staleHostView && sInboxModePan && sInboxModePan.view == staleHostView) {
            [staleHostView removeGestureRecognizer:sInboxModePan];
            [sInboxModePan removeTarget:nil action:NULL];
            if (sInboxModePanHost == (UIViewController *)controller) sInboxModePanHost = nil;
        }
        return;
    }

    UIView *hostView = ((UIViewController *)controller).view;
    if (!navigationBackdrop) {
        // Apollo's Liquid Glass navigation bar intentionally samples the
        // scrolling content beneath it. That looks good for ordinary lists,
        // but it makes notification text show through the fixed Inbox mode
        // controls while Chat's full-screen overlay remains opaque. Place a
        // noninteractive, theme-matched surface behind the navigation bar so
        // both modes have the same solid top area without changing the table's
        // native scrolling or bounce behavior.
        navigationBackdrop = [UIView new];
        navigationBackdrop.translatesAutoresizingMaskIntoConstraints = NO;
        navigationBackdrop.userInteractionEnabled = NO;
        [hostView addSubview:navigationBackdrop];
        [NSLayoutConstraint activateConstraints:@[
            [navigationBackdrop.topAnchor constraintEqualToAnchor:hostView.topAnchor],
            [navigationBackdrop.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
            [navigationBackdrop.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
            [navigationBackdrop.bottomAnchor constraintEqualToAnchor:hostView.safeAreaLayoutGuide.topAnchor],
        ]];
        objc_setAssociatedObject(controller, &kInboxAllNavigationBackdropKey, navigationBackdrop,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *backdropColor =
        ApolloModernChatThemeColor(((UIViewController *)controller).traitCollection, @"primary");
    if (![backdropColor isEqual:navigationBackdrop.backgroundColor]) {
        navigationBackdrop.backgroundColor = backdropColor;
    }

    if (!switcher) {
        UIView *original = tableView.tableHeaderView;
        objc_setAssociatedObject(controller, &kInboxAllOriginalHeaderKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat oldHeight = original ? CGRectGetHeight(original.frame) : 0.0;
        CGFloat width = CGRectGetWidth(tableView.bounds) ?: CGRectGetWidth(((UIViewController *)controller).view.bounds);
        UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, oldHeight + 60.0)];
        if (original) {
            original.frame = CGRectMake(0, 0, width, oldHeight);
            [wrapper addSubview:original];
        }
        // Keep an empty 60-point slot in the table header so the first
        // notification begins below the switcher. The switcher itself belongs
        // to the host view and stays pinned beneath the navigation bar while
        // rows scroll underneath it. This prevents the Notifications / Chat
        // labels from colliding with the centered Inbox title.
        switcher = [ApolloInboxModeSwitcherView new];
        switcher.translatesAutoresizingMaskIntoConstraints = NO;
        [switcher addTarget:controller action:NSSelectorFromString(@"apollo_inboxModeChanged:") forControlEvents:UIControlEventValueChanged];
        tableView.tableHeaderView = wrapper;
        [hostView addSubview:switcher];
        [NSLayoutConstraint activateConstraints:@[
            [switcher.topAnchor constraintEqualToAnchor:hostView.safeAreaLayoutGuide.topAnchor],
            [switcher.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
            [switcher.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
            [switcher.heightAnchor constraintEqualToConstant:60.0],
        ]];
        objc_setAssociatedObject(controller, &kInboxAllModeSwitcherKey, switcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Let the scroll hook above fade the switcher out of the way while
        // the native pull-to-refresh is revealed in the band it covers.
        objc_setAssociatedObject(tableView, &kInboxAllSwitcherTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, &kInboxAllSwitcherRefKey, switcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ChatsFilterLog(@"installed sticky Notifications / Chat switcher in Inbox (All)");
    }
    // Swipe between the two modes like adjacent pages: a leftward drag on
    // Notifications reveals Chat, a rightward drag on Chat returns to
    // Notifications — one direction-aware PAN on the host view covering the
    // notifications list and the Chat hub's web view alike (see
    // ApolloInboxWireModePanPrecedence for why a discrete swipe cannot work
    // over the hub, and the shared delegate's gestureRecognizerShouldBegin:
    // for the quadrant rule that keeps back/pop on Notifications and Apollo's
    // forward pan on Chat working untouched).
    if (!sInboxModePan) {
        sInboxModePan = [UIPanGestureRecognizer new];
        sInboxModePan.maximumNumberOfTouches = 1;
        sInboxModePan.delegate = [ApolloInboxSwipeGestureDelegate shared];
    }
    // Migrate the singleton to this host (addGestureRecognizer: detaches it
    // from any previous owner's view), guarded two ways:
    //   * never while the pan is actively tracking a touch — install passes
    //     arrive via async notifications (chat-status ticks, account
    //     changes), and yanking a Began/Changed recognizer off its view or
    //     swapping its target mid-drag kills the gesture, or delivers the
    //     end action to the wrong host;
    //   * an OFF-window instance may not steal the pan from an on-window
    //     owner — the status notification is broadcast to every live Inbox
    //     instance, and letting whichever install pass ran last win would
    //     silently strip the visible Inbox of its swipes until its next
    //     appearance. The frontmost host always reclaims the pan in
    //     viewDidAppear (a full install pass), by which point the outgoing
    //     owner has left the window.
    UIGestureRecognizerState panState = sInboxModePan.state;
    BOOL panTracking = (panState == UIGestureRecognizerStateBegan ||
                        panState == UIGestureRecognizerStateChanged);
    UIView *panOwnerView = sInboxModePan.view;
    BOOL mayClaim = !panTracking &&
        (hostView.window != nil || !panOwnerView || panOwnerView.window == nil);
    if (panOwnerView != hostView && mayClaim) {
        [hostView addGestureRecognizer:sInboxModePan];
    }
    if (sInboxModePan.view == hostView && !panTracking) {
        // Swap the (unretained) target in the same pass that sets the host
        // pointer so the two can never drift; recognizer targets are
        // unretained, so the pan must never keep a previous (possibly
        // deallocated) controller as its action target.
        [sInboxModePan removeTarget:nil action:NULL];
        [sInboxModePan addTarget:controller action:NSSelectorFromString(@"apollo_inboxModePanned:")];
        sInboxModePanHost = (UIViewController *)controller;
    }
    // Re-wire every install pass: cheap, idempotent (the static weak set
    // dedupes across reinstalls AND host lifetimes), and it catches pop/pan
    // recognizers that attach to the navigation container after first install
    // (plus WebKit's re-created edge recognizers).
    ApolloInboxWireModePanPrecedence((UIViewController *)controller, sInboxModePan);
    BOOL chatVisible = [objc_getAssociatedObject(controller, &kInboxAllChatHubVisibleKey) boolValue];
    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(controller, &kInboxAllChatHubKey);
    // The host switcher is the single live mode control in BOTH modes; it and
    // its backdrop always sit above the hub (see ApolloSetInboxChatHubVisible).
    // This function re-runs constantly (viewWillAppear, every chat-status
    // poll, trait changes), so every mutation below must be a no-op when the
    // state already matches. Unconditionally reordering the host view's
    // subviews on each pass permanently disengaged the native inbox list's
    // UIRefreshControl — after a routine status tick, pull-to-refresh stopped
    // triggering at all until the view controller was rebuilt.
    UIView *hubView = (chatVisible && hub.view.superview == hostView) ? hub.view : nil;
    NSArray<UIView *> *siblings = hostView.subviews;
    NSUInteger count = siblings.count;
    BOOL stackedCorrectly = count >= 2 &&
        siblings[count - 1] == switcher &&
        siblings[count - 2] == navigationBackdrop &&
        (!hubView || (count >= 3 && siblings[count - 3] == hubView));
    if (!stackedCorrectly) {
        if (hubView) [hostView bringSubviewToFront:hubView];
        [hostView bringSubviewToFront:navigationBackdrop];
        [hostView bringSubviewToFront:switcher];
    }
    [switcher apollo_setSelectedMode:chatVisible ? ApolloInboxModeChat : ApolloInboxModeNotifications animated:NO];
    [switcher apollo_refreshForTraits:((UIViewController *)controller).traitCollection];
    ApolloInboxEnsureRefreshHaptic(tableView);
}

#pragma mark - Boxes list: add the Direct Chat row

// Which index-path delegate methods must be remapped for the inserted Direct Chat row? Two layers:
//   * _TtC6Apollo23InboxListViewController's OWN methods (otool class metadata): initWithCoder:,
//     viewDidLoad, numberOfSectionsInTableView:, tableView:numberOfRowsInSection:,
//     tableView:cellForRowAtIndexPath:, tableView:heightForHeaderInSection:,
//     tableView:didSelectRowAtIndexPath:, redditAccountChangedWithNotification:. Of these the only
//     row/index-path ones are cellForRowAtIndexPath:/didSelectRowAtIndexPath: (remapped), numberOfRows
//     is overridden, and heightForHeaderInSection: is section-based.
//   * INHERITED methods matter too — respondsToSelector: (what UITableView dispatches on) sees the
//     whole chain. The runtime canary below caught that the base class _TtC6Apollo25ApolloTableViewController
//     implements tableView:heightForRowAtIndexPath:, which InboxListViewController inherits — so
//     UITableView calls it for every row with our *displayed* index paths. It returns a uniform
//     (self-sizing) height today, so the off-by-one was harmless in practice, but we remap it anyway
//     for correctness + safety (a future per-row height would otherwise mis-size). (Raised by @nickclyde.)
// The canary still watches the OTHER row selectors so a future Apollo build that adds one is caught.
static void ApolloWarnIfUnhandledRowDelegates(id vc) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Row-based selectors we do NOT remap; if Apollo (or a base class) starts implementing any, it
        // would receive our shifted *displayed* index paths unremapped. cellFor/didSelect/heightForRow
        // are handled below, so they're intentionally absent here.
        NSArray<NSString *> *risky = @[
            @"tableView:estimatedHeightForRowAtIndexPath:",
            @"tableView:willDisplayCell:forRowAtIndexPath:",
            @"tableView:didEndDisplayingCell:forRowAtIndexPath:",
            @"tableView:canEditRowAtIndexPath:",
            @"tableView:editActionsForRowAtIndexPath:",
            @"tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:",
            @"tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:",
            @"tableView:commitEditingStyle:forRowAtIndexPath:",
            @"tableView:contextMenuConfigurationForRowAtIndexPath:point:",
            @"tableView:accessoryButtonTappedForRowWithIndexPath:",
            @"tableView:canMoveRowAtIndexPath:",
            @"tableView:moveRowAtIndexPath:toIndexPath:",
        ];
        for (NSString *sel in risky) {
            if ([vc respondsToSelector:NSSelectorFromString(sel)])
                ApolloLog(@"[ChatsFilter] WARNING: InboxListViewController now implements %@ — the Direct Chat row shift may mis-index it; remap it too.", sel);
        }
    });
}

%hook _TtC6Apollo23InboxListViewController

- (void)viewDidLoad {
    %orig;
    sLatestBoxesController = self;
    ApolloBoxesState(self, YES);
    ApolloCaptureInboxTabBarItem((UIViewController *)self);
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    sLatestBoxesController = self;
    ApolloCaptureInboxTabBarItem((UIViewController *)self);
    ApolloApplyCombinedInboxBadge();
    // Section membership changes with moderator status. Force a fresh probe so
    // stale coordinates from the previous account cannot route the wrong row —
    // paired with a reload, never on its own (#865).
    ApolloBoxesResetRowStateAndReload(self, @"account switch");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sLatestBoxesController == self) ApolloRefreshBoxesForModeratorState(@"account switch +0.75s");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sLatestBoxesController == self) ApolloRefreshBoxesForModeratorState(@"account switch +2s");
    });
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    if (ApolloDirectChatRowActive()) ApolloWarnIfUnhandledRowDelegates(self);   // one-shot future-proofing canary
    long long n = %orig;
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloDirectChatRowActive() && ApolloBoxesUsesInsertedDirectChat(state) &&
        section == state.messagesSection) {
        n += 1;   // + our Direct Chat row
    }
    return n;
}

// Map a displayed row (with our inserted Direct Chat row) back to Apollo's real row in the
// Messages section. The Direct Chat row sits AT sMessagesRow (just above Messages); rows below it
// shift down by one. Returns -1 for the Direct Chat slot itself.
static NSInteger ApolloRealMessagesRow(ApolloBoxesRowState *state, NSInteger displayedRow) {
    if (!ApolloBoxesUsesInsertedDirectChat(state)) return displayedRow;
    if (displayedRow < state.messagesRow) return displayedRow;     // rows above Messages: unchanged
    if (displayedRow == state.messagesRow) return -1;              // our inserted Direct Chat row
    return displayedRow - 1;                                  // rows at/after Messages: shifted down
}

- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDirectChatRowActive()) return %orig;   // Direct Chat row disabled / keyless — leave Boxes untouched
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    // Detection pass: until we know which section/row holds "Messages", just observe.
    if (state.messagesSection < 0) {
        UITableViewCell *cell = %orig;
        NSString *text = ApolloCellText(cell);
        ApolloRememberSpecialBoxesCell(state, cell, indexPath);
        ChatsFilterLog(@"probe s=%ld r=%ld text=%@ cls=%@", (long)indexPath.section, (long)indexPath.row, text, NSStringFromClass([cell class]));
        if ([text isEqualToString:@"Messages"]) {
            state.messagesSection = indexPath.section;
            state.messagesRow = indexPath.row;
            BOOL native = ApolloBoxesHasNativeDirectChat(state);
            ChatsFilterLog(@"Messages at s=%ld r=%ld; %@ Direct Chat row + reloading",
                           (long)state.messagesSection, (long)state.messagesRow,
                           native ? @"reusing native" : @"inserting");
            UITableView *tv = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{ [tv reloadData]; });
        }
        return cell;
    }

    if (indexPath.section == state.messagesSection) {
        // When Apollo already provides this row, leave the data-source mapping
        // untouched. didSelect below decides whether it opens Apollo's legacy
        // chat or the new authenticated Reddit Chat.
        if (ApolloBoxesHasNativeDirectChat(state)) return %orig;
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (realRow < 0) {
            // our inserted Direct Chat row: borrow the Messages cell and restyle it
            NSIndexPath *real = [NSIndexPath indexPathForRow:state.messagesRow inSection:state.messagesSection];
            UITableViewCell *cell = %orig(tableView, real);
            ChatsFilterLog(@"cellFor displayed=%ld -> DirectChat (borrow r%ld, was '%@')", (long)indexPath.row, (long)state.messagesRow, ApolloCellText(cell));
            ApolloRestyleAsDirectChat(cell);
            return cell;
        }
        // every other row maps to its real Apollo row (Messages, and anything after it)
        NSIndexPath *real = [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection];
        UITableViewCell *cell = %orig(tableView, real);
        ChatsFilterLog(@"cellFor displayed=%ld -> real r%ld text='%@'", (long)indexPath.row, (long)realRow, ApolloCellText(cell));
        return cell;
    }
    UITableViewCell *cell = %orig;
    ApolloRememberSpecialBoxesCell(state, cell, indexPath);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloModernModmailShouldOpen() &&
        indexPath.section == state.moderatorMailSection && indexPath.row == state.moderatorMailRow) {
        ChatsFilterLog(@"Moderator Mail tapped -> opening modern authenticated web Modmail");
        UIViewController *controller = ApolloCreateModernModmailViewController();
        [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView deselectRowAtIndexPath:indexPath animated:NO];
        });
        return;
    }
    if (ApolloDirectChatRowActive() && state.messagesSection >= 0 && indexPath.section == state.messagesSection) {
        BOOL nativeChatRow = ApolloBoxesHasNativeDirectChat(state) && indexPath.row == state.nativeDirectChatRow;
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (nativeChatRow || realRow < 0) {
            if (ApolloModernChatShouldOpen()) {
                ChatsFilterLog(@"Direct Chat tapped -> opening modern Reddit Chat");
                UIViewController *controller = ApolloCreateModernChatViewController();
                [((UIViewController *)self).navigationController pushViewController:controller animated:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (NSIndexPath *selectedPath in ([tableView indexPathsForSelectedRows] ?: @[])) {
                        [tableView deselectRowAtIndexPath:selectedPath animated:NO];
                    }
                });
                return;
            }
            if (nativeChatRow) {
                ChatsFilterLog(@"Direct Chat tapped -> preserving Apollo legacy Chat");
                %orig;
                return;
            }
            ChatsFilterLog(@"Direct Chat tapped -> opening filtered messages list");
            sNextInboxIsChatFilter = YES;   // one-shot: the next InboxViewController filters to chats
            realRow = state.messagesRow;          // open the real Messages list (which we then filter)
        }
        %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection]);
        // We handed Apollo the REAL indexPath, so its own deselect-on-return clears the wrong row.
        // Defer to after the push settles and clear ALL selected rows (the index remap can leave
        // more than one marked) so the tapped row doesn't stay highlighted.
        NSIndexPath *tapped = indexPath;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSIndexPath *ip in ([tableView indexPathsForSelectedRows] ?: @[]))
                [tableView deselectRowAtIndexPath:ip animated:NO];
            [tableView deselectRowAtIndexPath:tapped animated:NO];
        });
        return;
    }
    %orig;
}

// Inherited from _TtC6Apollo25ApolloTableViewController (caught by the canary above) and therefore
// called by UITableView for every row — so it must be remapped like cellFor/didSelect, or rows
// at/after Messages get the height of the wrong real row and the Direct Chat row gets an arbitrary
// one. Map our displayed index path back to Apollo's real row; the Direct Chat row borrows the
// Messages row's height. (Raised by @nickclyde in review.)
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloBoxesRowState *state = ApolloBoxesState(self, YES);
    if (ApolloDirectChatRowActive() && ApolloBoxesUsesInsertedDirectChat(state) &&
        indexPath.section == state.messagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(state, indexPath.row);
        if (realRow < 0) realRow = state.messagesRow;   // Direct Chat row -> same height as the Messages row
        return %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:state.messagesSection]);
    }
    return %orig;
}

%end

#pragma mark - messages list: filter to chats

// Reddit's legacy-inbox chat mirrors carry a bracketed whole-subject marker —
// "[direct chat room]" / "[group chat room]" — never free text. The exact
// shape rule (single bracket pair spanning the entire trimmed subject, ending
// in "chat room", so a real PM that merely mentions a chat room can never be
// misclassified in either direction — raised by @jordanearle in review) lives
// in ApolloChatRoomDirectory, which also uses it to tell an unnamed room's
// mirror from a titled one when a tapped row is resolved to its Chat room.
static BOOL ApolloMessageSubjectIsChatRoomMirror(NSString *subject) {
    return ApolloChatSubjectIsRoomMarker(subject);
}

static BOOL ApolloMessageIsChatRoomMirror(id msg) {
    NSString *subject = nil;
    if ([msg respondsToSelector:@selector(subject)])
        subject = ((NSString *(*)(id, SEL))objc_msgSend)(msg, @selector(subject));
    return ApolloMessageSubjectIsChatRoomMirror(subject);
}

// Keep only chat-mirror messages (direct + group chats; regular PMs/modmail
// have a real subject, so they fall away).
static NSArray *ApolloChatFilterToChats(NSArray *messages) {
    if (![messages isKindOfClass:[NSArray class]]) return messages;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msg in messages) {
        if (ApolloMessageIsChatRoomMirror(msg)) [out addObject:msg];
    }
    ChatsFilterLog(@"filtered messages %lu -> %lu chats", (unsigned long)messages.count, (unsigned long)out.count);
    return out;
}

// Apollo's list is fed by a Swift Apollo.ListAdapterDataSource (not ObjC-hookable) reading the
// `messages` ivar, so we filter one level up: at the RDKClient message-inbox fetch, while the
// chat-filtered list is the visible one (sChatFilterActive). The Messages box itself never sets
// the flag, so it stays unfiltered.
static BOOL sChatFilterActive = NO;

// Reddit mirrors every chat message into the legacy message inbox, grouped
// per conversation (one thread row per room, the newest message as its
// preview). While modern Chat is on those rows stay listed — they are the
// inbox-side signal that a conversation moved — and a tap routes them to the
// Chat side (the ListAdapter hook at the end of this file), so Apollo's legacy
// thread UI never opens for them and the Inbox badge counts them once
// (ApolloCombinedInboxBadgeValue).

%hook _TtC6Apollo19InboxViewController

- (void)viewDidLoad {
    // Set the flag BEFORE %orig — Apollo's viewDidLoad kicks off the initial fetch, so the flag
    // must already be armed or that fetch slips through unfiltered.
    if (sNextInboxIsChatFilter) {
        sNextInboxIsChatFilter = NO;
        objc_setAssociatedObject(self, &kChatFilterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sChatFilterActive = YES;
        ChatsFilterLog(@"InboxViewController marked chat-filtered");
    }
    %orig;
    ApolloCaptureInboxTabBarItem((UIViewController *)self);
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue])
        ((UIViewController *)self).title = @"Direct Chat";   // after %orig so Apollo doesn't override it
    if (ApolloInboxControllerIsAll(self) && ![objc_getAssociatedObject(self, &kInboxAllStatusObserverKey) boolValue]) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:NSSelectorFromString(@"apollo_modernChatStatusChanged:")
                                                     name:ApolloModernChatStatusDidChangeNotification
                                                   object:nil];
        objc_setAssociatedObject(self, &kInboxAllStatusObserverKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloInstallInboxModeSwitcher(self); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ApolloInboxControllerIsAll(self) && ApolloModernChatShouldOpen()) {
                ApolloEnsureInboxChatHub((UIViewController *)self);
            }
        });
    }
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = YES;
    ApolloInstallInboxModeSwitcher(self);
    // The user is looking at the Inbox: refresh the chat unread count now
    // rather than waiting out the periodic cadence, and warm the chat room
    // directory so a tapped chat mirror can open its room without waiting.
    ApolloChatUnreadPollerKick();
    ApolloChatRoomDirectoryPrefetch();
    if (ApolloInboxControllerIsAll(self) && ApolloModernChatShouldOpen() &&
        !objc_getAssociatedObject(self, &kInboxAllChatHubKey)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloEnsureInboxChatHub((UIViewController *)self);
        });
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Only now is the host view attached under the navigation controller's
    // UILayoutContainerView, where Apollo's full-width pop pans live — the
    // earlier wiring passes cannot reach them — and only now can this host
    // reclaim the singleton mode-pan from a previous owner (the migration
    // refuses to steal from an on-window view, and during the push/pop
    // transition the outgoing owner was still on-window). Run the full
    // install pass: idempotent, and it ends with the wiring pass.
    if (ApolloInboxControllerIsAll(self) && ApolloModernChatShouldOpen()) {
        ApolloInstallInboxModeSwitcher(self);
    }
}

// Apollo notifies every inbox surface on account switches. The persistent
// Chat hub is seeded with one account's cookies, so it must be destroyed at
// this exact moment — keeping it would show (and compose as) the previous
// account. The switcher install below re-derives ShouldOpen for the new
// account, and the ensure re-preloads a hub with the new identity.
- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    if (!ApolloInboxControllerIsAll(self)) return;
    ApolloDismantleInboxChatHub((UIViewController *)self, @"account changed");
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloInstallInboxModeSwitcher(self);
        if (ApolloModernChatShouldOpen()) {
            ApolloEnsureInboxChatHub((UIViewController *)self);
        }
    });
}

- (void)dealloc {
    // The singleton mode-pan holds its action targets unretained, and a host
    // that dies with the feature still on never runs the disable path's
    // target cleanup — strip this controller's pair so the immortal pan can
    // never message a deallocated host. (removeTarget: matches by pointer;
    // no-op for every other host and for a nil pan.)
    [sInboxModePan removeTarget:self action:NULL];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

%new
- (void)apollo_modernChatStatusChanged:(NSNotification *)notification {
    ApolloInstallInboxModeSwitcher(self);
    ApolloApplyCombinedInboxBadge();
}

%new
- (void)apollo_inboxModeChanged:(ApolloInboxModeSwitcherView *)sender {
    // The host switcher stays above the hub as the single live mode control,
    // so it now receives the Chat -> Notifications tap too (the hub's own
    // switcher is hidden whenever a host switcher exists).
    if (sender.selectedMode == ApolloInboxModeNotifications) {
        BOOL chatVisible = [objc_getAssociatedObject(self, &kInboxAllChatHubVisibleKey) boolValue];
        if (!chatVisible) return;
        ChatsFilterLog(@"Inbox (All) switching in place from Chat hub back to Notifications");
        ApolloSetInboxChatHubVisible((UIViewController *)self, NO, YES);
        return;
    }
    if (sender.selectedMode != ApolloInboxModeChat || !ApolloModernChatShouldOpen()) return;
    ChatsFilterLog(@"Inbox (All) switching in place from Notifications to Chat hub");
    ApolloSetInboxChatHubVisible((UIViewController *)self, YES, YES);
}

// The swipe drives its transition frame by frame, like every other iOS
// navigation gesture: the pages track the finger and a release either carries
// them the rest of the way or puts them back. Chat is three levels deep inside
// Inbox and a back gesture climbs them one at a time — conversation -> chat
// list -> Notifications -> out of Inbox — so which transition runs depends on
// what is open, not on which way the finger moved.
%new
- (void)apollo_inboxModePanned:(UIPanGestureRecognizer *)pan {
    if (!ApolloInboxControllerIsAll(self) || !ApolloModernChatShouldOpen()) return;
    UIViewController *host = (UIViewController *)self;
    ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(self, &kInboxAllChatHubKey);
    BOOL chatVisible = [objc_getAssociatedObject(self, &kInboxAllChatHubVisibleKey) boolValue];
    // Same RTL mirror as the delegate's quadrant rule.
    CGFloat rtlSign = (pan.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    CGFloat direction = (chatVisible ? 1.0 : -1.0) * rtlSign;   // toward Notifications : toward Chat
    CGFloat width = CGRectGetWidth(host.view.bounds);
    CGPoint translation = [pan translationInView:pan.view];
    CGPoint velocity = [pan velocityInView:pan.view];
    CGFloat progress = width > 0.0 ? (translation.x * direction) / width : 0.0;
    CGFloat commitVelocity = velocity.x * direction;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            sInboxSwipeInteractive = NO;
            if (chatVisible && ApolloModernChatControllerIsOnConversationRoute(hub.chatController)) {
                sInboxSwipeKind = ApolloInboxSwipeKindConversationBack;
                // NO here means there is nothing to reveal yet (no captured
                // list frame, or a back already running); the release below
                // then falls back to the plain, instant step.
                sInboxSwipeInteractive =
                    ApolloModernChatControllerBeginInteractiveBack(hub.chatController);
            } else {
                sInboxSwipeKind = ApolloInboxSwipeKindMode;
                sInboxSwipeInteractive = ApolloInboxBeginModeTransition(host, !chatVisible);
            }
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!sInboxSwipeInteractive) break;
            if (sInboxSwipeKind == ApolloInboxSwipeKindConversationBack) {
                ApolloModernChatControllerUpdateInteractiveBack(hub.chatController, progress);
            } else if (sInboxSwipeKind == ApolloInboxSwipeKindMode) {
                ApolloInboxUpdateModeTransition(host, progress);
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            ApolloInboxSwipeKind kind = sInboxSwipeKind;
            BOOL interactive = sInboxSwipeInteractive;
            sInboxSwipeKind = ApolloInboxSwipeKindNone;
            sInboxSwipeInteractive = NO;
            if (kind == ApolloInboxSwipeKindNone) break;
            // One commit rule for every chat-hierarchy swipe (the standalone
            // Chat screen's back-pan uses the same one): past the halfway
            // point, or a decisive throw in the same direction — with the
            // axis-dominance check that keeps a drag which turned into a
            // vertical list scroll from flipping tabs on release.
            BOOL commit = ApolloModernChatBackSwipeCommits(pan.state, progress, commitVelocity, translation);
            if (kind == ApolloInboxSwipeKindConversationBack) {
                if (commit) ChatsFilterLog(@"Inbox (All) swipe: Chat conversation -> chat list");
                if (interactive) {
                    ApolloModernChatControllerFinishInteractiveBack(hub.chatController,
                                                                    commit, commitVelocity);
                } else if (commit) {
                    ApolloModernChatControllerGoBackToConversationList(hub.chatController);
                }
                break;
            }
            if (commit) {
                ChatsFilterLog(@"Inbox (All) swipe: %@", chatVisible ? @"Chat hub -> Notifications"
                                                                     : @"Notifications -> Chat hub");
            }
            if (interactive) {
                ApolloInboxFinishModeTransition(host, commit, commitVelocity);
            } else if (commit) {
                ApolloSetInboxChatHubVisible(host, !chatVisible, YES);
            }
            break;
        }
        default:
            break;
    }
}

%new
- (void)apollo_openModernChatFromAllInbox {
    // Retain the old selector for callers from builds that cached the previous
    // table header; the next appearance replaces that header with the switcher.
    if (!ApolloModernChatShouldOpen()) return;
    ApolloSetInboxChatHubVisible((UIViewController *)self, YES, YES);
}
%end

// Safety: opening a chat THREAD must never run with the inbox-list filter armed, or a thread
// refresh that happens to use messagesInCategory could be filtered. Clear the flag on thread show.
%hook _TtC6Apollo28PrivateMessageViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    sChatFilterActive = NO;
}
%end

// Re-entrancy guard for the accumulate-paging below: a nested page-pull does a single filtered page
// and passes the real pagination token straight through (it must NOT re-accumulate). The flag is only
// ever toggled synchronously on the main thread around the nested call (the call just kicks off an
// async task and returns), so a plain BOOL needs no lock.
static BOOL sChatPagingInProgress = NO;
static const NSInteger kMaxChatFilterPages = 8;   // cap so a chat-sparse account can't page forever

%hook RDKClient
// NOTE: `category` is an enum (NSInteger), NOT an object — declaring it `id` makes ARC retain
// the integer value as a pointer (EXC_BAD_ACCESS at 0x2). It MUST be a scalar type.
- (id)messagesInCategory:(long long)category pagination:(id)pagination markRead:(BOOL)markRead completion:(id)completion {
    ChatsFilterLog(@"messagesInCategory cat=%lld active=%d nested=%d",
                   category, sChatFilterActive, sChatPagingInProgress);
    if (!completion) return %orig;

    if (!sChatFilterActive) return %orig;

    // A nested page-pull kicked off by the accumulator below: filter this one page and pass the real
    // pagination token straight through so the accumulator can decide whether to keep going.
    if (sChatPagingInProgress) {
        id wrapped = ^(NSArray *messages, id page, NSError *error) {
            ((void (^)(NSArray *, id, NSError *))completion)(ApolloChatFilterToChats(messages), page, error);
        };
        return %orig(category, pagination, NO, wrapped);
    }

    // Top-level chat-filtered load. Filtering one page to chats can leave it EMPTY when that page holds
    // only non-chat PMs — and Apollo's list (IGListKit) only requests the next page when its bottom
    // LoadNextPage cell appears, which an empty list never shows, so older chats further back would
    // never load. So accumulate across pages until we have at least one chat (or Reddit runs out of
    // pages, or we hit the cap), then deliver a non-empty page carrying the LAST page's pagination
    // token so Apollo's own load-more continues from where we stopped. (Reported by @nickclyde in
    // review.) RDKPagination.after is an NSString (verified in the binary); nil/empty == no more pages.
    NSMutableArray *acc = [NSMutableArray array];
    __block NSInteger pages = 0;
    __weak id weakSelf = self;   // RDKClient is only forward-declared here; message it dynamically
    void (^deliver)(id, NSError *) = ^(id page, NSError *error) {
        ((void (^)(NSArray *, id, NSError *))completion)(acc, page, error);
    };
    // The page-puller references itself (via the __block `step`) to recurse, then nils itself when it
    // stops, so the self-reference is deliberately broken — silence the (correct-in-general) retain
    // cycle warning for just this block. The block is strongly held by the in-flight fetch's completion
    // until we nil it on delivery, so liveness is guaranteed and there's no actual leak.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    __block void (^step)(NSArray *, id, NSError *) = nil;
    step = ^(NSArray *chats, id page, NSError *error) {
        [acc addObjectsFromArray:(chats ?: @[])];
        pages++;
        // RDKPagination.after is an NSString (verified in the binary) but RDKPagination isn't imported,
        // so read it dynamically; nil/empty == no more pages.
        NSString *after = [page respondsToSelector:@selector(after)]
            ? ((NSString *(*)(id, SEL))objc_msgSend)(page, @selector(after)) : nil;
        BOOL morePages = ([after isKindOfClass:[NSString class]] && after.length > 0);
        id ss = weakSelf;
        if (acc.count == 0 && morePages && !error && ss && pages < kMaxChatFilterPages) {
            ChatsFilterLog(@"page %ld had 0 chats; pulling next (after=%@)", (long)pages, after);
            sChatPagingInProgress = YES;
            ((id (*)(id, SEL, long long, id, BOOL, id))objc_msgSend)(
                ss, @selector(messagesInCategory:pagination:markRead:completion:), category, page, (BOOL)NO, step);
            sChatPagingInProgress = NO;
        } else {
            ChatsFilterLog(@"delivering %lu chat(s) after %ld page(s)", (unsigned long)acc.count, (long)pages);
            deliver(page, error);
            step = nil;   // break the recursive block's self-reference so it deallocs
        }
    };
#pragma clang diagnostic pop
    id firstWrapped = ^(NSArray *messages, id page, NSError *error) {
        step(ApolloChatFilterToChats(messages), page, error);
    };
    return %orig(category, pagination, NO, firstWrapped);   // markRead:NO so the filtered view doesn't mark PMs read
}
%end

#pragma mark - sender avatar / subreddit icon on inbox rows

// The inbox is AsyncDisplayKit (Texture): each row is an Apollo.InboxCellNode backed by an RDKMessage
// in its `message` ivar. We overlay a small circular image to the left of the row's identity button,
// gated by the Show User Avatars toggle. Identity is resolved from the MODEL (not parsed text):
//   - reply/mention notifications (contentType 0/1/2) -> the other user's avatar (message.author)
//   - PM to/from a subreddit (modmail / "to #sub")     -> the subreddit's icon (message.subreddit)
//   - sent PM        -> the recipient's avatar (message.recipient)
//   - received PM / direct chat room -> the sender's avatar (message.author)
//   - new-modmail rows (message nil) -> the conversation's subreddit icon, else the participant avatar
#define APOLLO_INBOX_AVATAR_DEBUG 0   // flip to 1 for verbose per-row resolved kind/identity logging

static char kInboxAvatarKey;          // on the cell's view: our image UIImageView
static char kInboxAvatarIdentityKey;  // on the image view: the identity it currently shows ("u:name" / "r:sub")

typedef NS_ENUM(NSInteger, ApolloInboxIconKind) {
    ApolloInboxIconNone = 0,
    ApolloInboxIconUser,
    ApolloInboxIconSubreddit,
};

static CGRect ApolloNodeFrame(id node) {
    if (![node respondsToSelector:@selector(frame)]) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame));
}

// Read a Swift/ObjC ivar by name off any object (the InboxCellNode's model + button-node ivars).
static id ApolloInboxIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        @try { return object_getIvar(object, ivar); }
        @catch (__unused NSException *e) { return nil; }
    }
    return nil;
}

static NSString *ApolloInboxStringProp(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *ApolloInboxNormUser(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

// Subreddit name as the icon caches want it: the caches strip "r/" variants + lowercase internally,
// but they do NOT strip a leading "#" (modmail dests like "#dbz"), so do that here.
static NSString *ApolloInboxSubredditClean(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSString *s = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s hasPrefix:@"#"]) s = [[s substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0 || [s isEqualToString:@"[deleted]"]) return nil;
    return s;
}

static NSString *ApolloInboxUsernameFromObject(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:[NSString class]]) return ApolloInboxNormUser(object);
    NSString *u = ApolloInboxStringProp(object, @selector(author));
    if (!u) u = ApolloInboxStringProp(object, @selector(username));
    if (!u) u = ApolloInboxStringProp(object, @selector(name));
    return ApolloInboxNormUser(u);
}

static NSString *ApolloInboxCurrentUser(void) {
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedClient)]) return nil;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient));
    if (!client || ![client respondsToSelector:@selector(currentUser)]) return nil;
    id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    return ApolloInboxUsernameFromObject(user);
}

// Resolve the row's icon kind + identity string + the button node to anchor the overlay to.
static ApolloInboxIconKind ApolloInboxResolveIdentity(id cellNode, NSString **outIdentity, id *outAnchor) {
    *outIdentity = nil;
    if (outAnchor) *outAnchor = nil;

    id msg = ApolloInboxIvarValue(cellNode, @"message");
    if (msg) {
        long long ct = [msg respondsToSelector:@selector(contentType)]
            ? ((long long (*)(id, SEL))objc_msgSend)(msg, @selector(contentType)) : -1;
        NSString *author    = ApolloInboxStringProp(msg, @selector(author));
        NSString *recipient = ApolloInboxStringProp(msg, @selector(recipient));
        NSString *subreddit = ApolloInboxStringProp(msg, @selector(subreddit));

        if (ct == 0 || ct == 1 || ct == 2) {
            // post reply / comment reply / username mention -> the other user (the replier/mentioner).
            NSString *u = ApolloInboxNormUser(author);
            if (u) { *outIdentity = u; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"authorButtonNode"); return ApolloInboxIconUser; }
            // Replier/mentioner is deleted/suspended: fall back to the community icon if we know it.
            NSString *s = ApolloInboxSubredditClean(subreddit);
            if (s) {
                *outIdentity = s;
                if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode") ?: ApolloInboxIvarValue(cellNode, @"authorButtonNode");
                return ApolloInboxIconSubreddit;
            }
        } else {
            // PM (contentType 3) or unknown: a non-empty subreddit means a modmail/subreddit message.
            NSString *s = ApolloInboxSubredditClean(subreddit);
            if (s) { *outIdentity = s; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode"); return ApolloInboxIconSubreddit; }

            // Sent vs received: I sent it IFF I'm the author. recipientButtonNode exists on BOTH sent
            // and received rows (Apollo renders "to <other>" / the sender alike), so it can't decide
            // this — it's only a fallback when the current user is unknown. Show the OTHER party.
            NSString *me = ApolloInboxCurrentUser();
            BOOL sent;
            if (me.length && author.length) sent = ([me caseInsensitiveCompare:author] == NSOrderedSame);
            else                            sent = (ApolloInboxIvarValue(cellNode, @"recipientButtonNode") != nil);

            NSString *other = sent ? ApolloInboxNormUser(recipient) : ApolloInboxNormUser(author);
            // Never paint the logged-in user's own avatar (e.g. a note-to-self where recipient == me).
            if (other.length && me.length && [other caseInsensitiveCompare:me] == NSOrderedSame) other = nil;
            if (other.length) {
                *outIdentity = other;
                if (outAnchor) *outAnchor = sent ? (ApolloInboxIvarValue(cellNode, @"recipientButtonNode") ?: ApolloInboxIvarValue(cellNode, @"authorButtonNode"))
                                                 : ApolloInboxIvarValue(cellNode, @"authorButtonNode");
                return ApolloInboxIconUser;
            }
        }
        return ApolloInboxIconNone;   // a message is present but nothing resolvable — don't guess
    }

    // New-modmail rows (no classic RDKMessage). RDKModmailConversationInfo has no subreddit ivar — the
    // community lives in its `_owner` dict (Reddit owner:{type,displayName,id}); the participant is
    // RDKModmailMessage._author (an RDKModmailAuthor exposing `name`). Best-effort + fully defensive.
    id mmConv = ApolloInboxIvarValue(cellNode, @"newModmailConversationInfo");
    id mmMsg  = ApolloInboxIvarValue(cellNode, @"newModmailMessage");
    if (mmConv || mmMsg) {
        id owner = ApolloInboxIvarValue(mmConv, @"_owner") ?: ApolloInboxIvarValue(mmConv, @"owner");
        if ([owner isKindOfClass:[NSDictionary class]]) {
            NSString *s = ApolloInboxSubredditClean([(NSDictionary *)owner objectForKey:@"displayName"]);
            if (s) { *outIdentity = s; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"subredditButtonNode"); return ApolloInboxIconSubreddit; }
        }
        id mmAuthor = ApolloInboxIvarValue(mmMsg, @"_author") ?: ApolloInboxIvarValue(mmMsg, @"author");
        NSString *u = ApolloInboxUsernameFromObject(mmAuthor);
        if (u) { *outIdentity = u; if (outAnchor) *outAnchor = ApolloInboxIvarValue(cellNode, @"authorButtonNode"); return ApolloInboxIconUser; }
    }
    return ApolloInboxIconNone;
}

static void ApolloInboxCellApplyAvatar(id cellNode) {
    UIView *cellView = [cellNode respondsToSelector:@selector(view)]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view)) : nil;
    if (![cellView isKindOfClass:[UIView class]]) return;
    UIImageView *av = objc_getAssociatedObject(cellView, &kInboxAvatarKey);

    if (!sShowUserAvatars) { if (av) av.hidden = YES; return; }   // toggle off — definitive hide

    NSString *identity = nil; id anchorBtn = nil;
    ApolloInboxIconKind kind = ApolloInboxResolveIdentity(cellNode, &identity, &anchorBtn);

    // Nothing resolvable (unsupported row, or the model isn't attached yet): don't show a stale image.
    if (kind == ApolloInboxIconNone || identity.length == 0) { if (av) av.hidden = YES; return; }

    static const CGFloat d = 20.0, gap = 6.0;
    if (!av) {
        av = [[UIImageView alloc] init];
        av.contentMode = UIViewContentModeScaleAspectFill;
        av.clipsToBounds = YES;
        av.layer.cornerRadius = d / 2.0;
        av.backgroundColor = [UIColor secondarySystemFillColor];
        objc_setAssociatedObject(cellView, &kInboxAvatarKey, av, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (av.superview != cellView) [cellView addSubview:av];   // re-add if Texture stripped it
    [cellView bringSubviewToFront:av];
    av.hidden = NO;
    // Anchor to the kind-specific identity button; fall back to a cell-relative position (the identity
    // row sits ~25px above the cell bottom) so the image stays put before the buttons are laid out.
    CGRect bf = ApolloNodeFrame(anchorBtn);
    BOOL frameOK = anchorBtn && bf.origin.x > 10.0 && bf.size.height > 0.0;
    CGFloat ax = frameOK ? bf.origin.x - d - gap : 12.0;
    CGFloat ay = frameOK ? bf.origin.y + (bf.size.height - d) / 2.0 : cellView.bounds.size.height - 27.0;
    av.frame = CGRectMake(ax, ay, d, d);

    // Composite identity key so a recycled cell that flipped user<->subreddit can't paint a stale image.
    NSString *idKey = [NSString stringWithFormat:@"%@:%@", kind == ApolloInboxIconSubreddit ? @"r" : @"u", identity];
    BOOL identityChanged = ![objc_getAssociatedObject(av, &kInboxAvatarIdentityKey) isEqualToString:idKey];
    // Skip only when we're already SHOWING the right image. If the identity matches but the image is
    // still nil (a prior fetch failed or hasn't returned yet), fall through and retry — otherwise one
    // transient failure would leave a permanent grey placeholder for that identity.
    if (av.image && !identityChanged) return;
    if (identityChanged) {
        objc_setAssociatedObject(av, &kInboxAvatarIdentityKey, idKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        av.image = nil;
#if APOLLO_INBOX_AVATAR_DEBUG
        ChatsFilterLog(@"inbox icon -> %@", idKey);
#endif
    }

    __weak UIImageView *wav = av;
    void (^applyImg)(UIImage *) = ^(UIImage *img) {
        UIImageView *sav = wav;
        if (img && sav && [objc_getAssociatedObject(sav, &kInboxAvatarIdentityKey) isEqualToString:idKey]) sav.image = img;
    };

    if (kind == ApolloInboxIconSubreddit) {
        // user-set custom icon wins, then a cached community icon, then async fetch.
        ApolloSubredditCustomIconCache *cic = [ApolloSubredditCustomIconCache sharedCache];
        UIImage *custom = [cic cachedIconForSubreddit:identity];
        if (custom) { applyImg(custom); return; }
        ApolloSubredditInfoCache *sic = [ApolloSubredditInfoCache sharedCache];
        ApolloUserProfileCache *imgCache = [ApolloUserProfileCache sharedCache];
        ApolloSubredditInfo *sinfo = [sic cachedInfoForSubreddit:identity];
        UIImage *subImg = sinfo.iconURL ? [imgCache cachedImageForURL:sinfo.iconURL] : nil;
        if (subImg) { applyImg(subImg); return; }
        [sic requestInfoForSubreddit:identity completion:^(ApolloSubredditInfo *i2) {
            if ([cic hasCustomIconForSubreddit:identity]) return;   // a custom icon arrived meanwhile
            if (i2.iconURL) [imgCache requestImageForURL:i2.iconURL completion:applyImg];
        }];
        return;
    }

    // user avatar
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *info = [cache cachedInfoForUsername:identity];
    NSURL *u = info ? (info.iconURL ?: info.snoovatarURL) : nil;
    UIImage *userImg = u ? [cache cachedImageForURL:u] : nil;
    if (userImg) { applyImg(userImg); return; }
    [cache requestInfoForUsername:identity completion:^(ApolloUserProfileInfo *i2) {
        NSURL *uu = i2.iconURL ?: i2.snoovatarURL;
        if (uu) [cache requestImageForURL:uu completion:applyImg];
    }];
}

%hook _TtC6Apollo13InboxCellNode
- (void)layout {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
}
- (void)didEnterVisibleState {
    %orig;
    @try { ApolloInboxCellApplyAvatar(self); } @catch (__unused id e) {}
    // The identity button nodes may not be laid out yet on first visibility; re-apply a couple of
    // times shortly after so the image anchors correctly + re-attaches without needing a scroll.
    __weak id wself = self;
    for (NSTimeInterval delay = 0.25; delay <= 0.8; delay += 0.55) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { if (wself) ApolloInboxCellApplyAvatar(wself); } @catch (__unused id e) {}
        });
    }
}
%end

%hook UITabBarItem

- (void)setBadgeValue:(NSString *)badgeValue {
    if (objc_getAssociatedObject(self, &kApolloInboxApplyingCombinedBadgeKey)) {
        %orig;
        return;
    }

    BOOL titleIdentifiesInbox = self.title.length > 0 &&
        [self.title caseInsensitiveCompare:@"Inbox"] == NSOrderedSame;
    if (titleIdentifiesInbox && self != sApolloInboxTabBarItem) {
        sApolloInboxTabBarItem = self;
        objc_setAssociatedObject(self, &kApolloInboxBadgeInitializedKey,
                                 @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (self != sApolloInboxTabBarItem) {
        %orig;
        return;
    }

    objc_setAssociatedObject(self, &kApolloInboxNativeBadgeValueKey,
                             badgeValue, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, &kApolloInboxBadgeInitializedKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *combinedValue = ApolloCombinedInboxBadgeValue(badgeValue);
    ChatsFilterLog(@"Inbox badge native=%@ chat=%ld combined=%@",
                   badgeValue ?: @"none", (long)ApolloModernChatUnreadBadgeCount(),
                   combinedValue ?: @"none");
    %orig(combinedValue);
}

%end

#pragma mark - native inbox rows: open chat mirrors in modern Chat

// Reddit mirrors every modern Chat message into the legacy inbox as a private
// message, one thread row per conversation: direct chats under the
// "[direct chat room]" marker, converted message threads and titled group
// rooms under their title. Those rows are the inbox-side signal that a
// conversation moved, but tapping one pushed Apollo's legacy thread, a dead
// end next to the modern Chat surface one switch away. With modern Chat on,
// the tap now resolves the mirror to its Chat room (ApolloChatRoomDirectory)
// and opens it there: in place inside the Inbox (All) hub, or as a pushed Chat
// controller from any other inbox list (Unread, Messages, Sent). When no room
// can be matched the tap falls through to Apollo's own handler, so the legacy
// thread stays the safety net. With modern Chat off nothing here runs.

static BOOL sInboxChatMirrorBypass = NO;   // re-entry: run Apollo's handler for the fallback

static UIViewController *ApolloInboxHostControllerForTableNode(id tableNode) {
    Class inboxClass = objc_getClass("_TtC6Apollo19InboxViewController");
    if (!inboxClass || ![tableNode respondsToSelector:@selector(view)]) return nil;
    UIResponder *responder = ((UIView *(*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
    while (responder) {
        if ([responder isKindOfClass:inboxClass]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

// A private message that can be a chat mirror: not a post/comment reply or a
// mention, not a subreddit/moderator message, not admin-distinguished.
static BOOL ApolloInboxMessageMayBeChatMirror(id message) {
    Class messageClass = objc_getClass("RDKMessage");
    Class replyClass = objc_getClass("RDKCommentReplyMessage");
    if (!messageClass || ![message isKindOfClass:messageClass]) return NO;
    if (replyClass && [message isKindOfClass:replyClass]) return NO;
    if ([message respondsToSelector:@selector(isCommentReply)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(message, @selector(isCommentReply))) return NO;
    long long contentType = [message respondsToSelector:@selector(contentType)]
        ? ((long long (*)(id, SEL))objc_msgSend)(message, @selector(contentType)) : -1;
    if (contentType >= 0 && contentType <= 2) return NO;   // post reply / comment reply / mention
    if (ApolloInboxSubredditClean(ApolloInboxStringProp(message, @selector(subreddit)))) return NO;
    if (ApolloInboxStringProp(message, @selector(distinguished)).length > 0) return NO;
    return ApolloInboxStringProp(message, @selector(subject)).length > 0;
}

// Swap a Swift class-typed stored property — a plain strong reference the
// ObjC runtime has no layout information for — the way the compiled setter
// does: retain the new value, store it, release the old one.
static BOOL ApolloInboxSwapObjectIvar(id object, const char *name, id value) {
    if (!object || !name) return NO;
    Ivar ivar = NULL;
    for (Class cls = [object class]; cls && cls != [NSObject class] && !ivar; cls = class_getSuperclass(cls)) {
        ivar = class_getInstanceVariable(cls, name);
    }
    ptrdiff_t offset = ivar ? ivar_getOffset(ivar) : 0;
    if (offset <= 0) return NO;
    void **slot = (void **)((uint8_t *)(__bridge void *)object + offset);
    void *previous = *slot;
    *slot = (__bridge_retained void *)value;
    if (previous) CFRelease(previous);
    return YES;
}

// The row's section controller, reachable as the cell node's action delegate
// (a Swift existential whose first word is the object it wraps; a class check
// guards the read).
static id ApolloInboxSectionControllerForCellNode(id node) {
    Class sectionClass = objc_getClass("_TtC6Apollo22InboxSectionController");
    Ivar ivar = node ? class_getInstanceVariable([node class], "actionDelegate") : NULL;
    ptrdiff_t offset = ivar ? ivar_getOffset(ivar) : 0;
    if (!sectionClass || offset <= 0) return nil;
    void *candidate = *(void **)((uint8_t *)(__bridge void *)node + offset);
    if (!candidate) return nil;
    id object = (__bridge id)candidate;
    return [object isKindOfClass:sectionClass] ? object : nil;
}

// Opening the legacy thread marked the message read; do the same here, the
// way Apollo's own swipe action does it: a read copy of the model, the API
// call, the copy swapped into the row's section controller (so the row
// rebuilds from it) and the ModelObjectUpdated broadcast every inbox list
// observes to swap its own model. The broadcast alone updates the counts but
// leaves the tapped row's cell painted unread — its cell is rebuilt through
// Apollo's own cell builder by reloading the row.
static void ApolloInboxMarkMessageRead(id message, id cellNode, id tableNode, NSIndexPath *indexPath) {
    if (![message respondsToSelector:@selector(isUnread)] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(message, @selector(isUnread))) return;
    if (![message conformsToProtocol:@protocol(NSCopying)]) return;
    id updated = [message copy];
    if (![updated respondsToSelector:@selector(setUnread:)]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(updated, @selector(setUnread:), NO);
    Class clientClass = objc_getClass("RDKClient");
    id client = clientClass && [clientClass respondsToSelector:@selector(sharedClient)]
        ? ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient)) : nil;
    if ([client respondsToSelector:@selector(markMessageAsRead:completion:)]) {
        ((id (*)(id, SEL, id, id))objc_msgSend)(client, @selector(markMessageAsRead:completion:), updated, nil);
    }
    id sectionController = ApolloInboxSectionControllerForCellNode(cellNode);
    BOOL swapped = ApolloInboxSwapObjectIvar(sectionController, "message", updated);
    if (swapped) ApolloInboxSwapObjectIvar(cellNode, "message", updated);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.christianselig.ModelObjectUpdated"
                                                        object:message
                                                      userInfo:@{ @"newModel": updated }];
    if (swapped && indexPath && [tableNode respondsToSelector:@selector(reloadRowsAtIndexPaths:withRowAnimation:)]) {
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(tableNode, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                                                        @[indexPath], (NSInteger)UITableViewRowAnimationNone);
    }
    ChatsFilterLog(@"marked the tapped chat mirror read (row %@)", swapped ? @"rebuilt" : @"left to the list's next reload");
}

static void ApolloInboxOpenChatPath(UIViewController *host, NSString *chatPath) {
    // A mirror of a pending chat request has no room to open yet: show the
    // Requests list, where Reddit keeps it until it is accepted.
    BOOL requests = [chatPath isEqualToString:ApolloChatRequestsPath];
    if (ApolloInboxControllerIsAll(host)) {
        // Same transition as tapping the Chat switch, then straight into the
        // room; the hub's Messages section is where the room's Back leads.
        ApolloSetInboxChatHubVisible(host, YES, YES);
        ApolloInboxChatHubViewController *hub = objc_getAssociatedObject(host, &kInboxAllChatHubKey);
        if (hub && requests) {
            [hub apollo_showSection:ApolloModernChatInboxSectionRequests animated:NO];
            ChatsFilterLog(@"opened the Chat hub's Requests for a pending-request mirror");
            return;
        }
        if (hub) {
            [hub.sectionSwitcher apollo_setSelectedSection:ApolloModernChatInboxSectionMessages animated:NO];
            ApolloModernChatControllerOpenConversationPath(hub.chatController, chatPath);
            ChatsFilterLog(@"opened a chat mirror's room in the Inbox Chat hub");
            return;
        }
    }
    UIViewController *controller = ApolloCreateModernChatViewControllerForPath(chatPath);
    [host.navigationController pushViewController:controller animated:YES];
    ChatsFilterLog(@"opened a chat mirror's %@ in a pushed Chat controller",
                   requests ? @"pending request list" : @"room");
}

static BOOL ApolloInboxOpenChatMirrorIfNeeded(id listAdapter, id tableNode, NSIndexPath *indexPath) {
    if (sInboxChatMirrorBypass || !ApolloModernChatShouldOpen()) return NO;
    if (![tableNode respondsToSelector:@selector(nodeForRowAtIndexPath:)]) return NO;
    id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, @selector(nodeForRowAtIndexPath:), indexPath);
    Class cellClass = objc_getClass("_TtC6Apollo13InboxCellNode");
    if (!cellClass || ![node isKindOfClass:cellClass]) return NO;
    id message = ApolloInboxIvarValue(node, @"message");
    if (!ApolloInboxMessageMayBeChatMirror(message)) return NO;
    UIViewController *host = ApolloInboxHostControllerForTableNode(tableNode);
    if (!host) return NO;

    NSString *subject = ApolloInboxStringProp(message, @selector(subject));
    NSString *author = ApolloInboxStringProp(message, @selector(author));
    NSString *recipient = ApolloInboxStringProp(message, @selector(recipient));
    NSString *me = ApolloInboxCurrentUser() ?: ApolloActiveWebSessionUsername();
    BOOL sent = me.length > 0 && author.length > 0 && [me caseInsensitiveCompare:author] == NSOrderedSame;
    NSString *partner = sent ? recipient : author;
    if (partner.length == 0 || [partner hasPrefix:@"["]) partner = nil;   // "[deleted]"
    NSDate *created = [message respondsToSelector:@selector(createdUTC)]
        ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(createdUTC)) : nil;
    NSTimeInterval timestamp = [created isKindOfClass:[NSDate class]] ? created.timeIntervalSince1970 : 0;
    ChatsFilterLog(@"chat mirror tapped (%@, partner %@); resolving its modern Chat room",
                   ApolloChatSubjectIsRoomMarker(subject) ? @"unnamed room" : @"titled room",
                   partner.length ? @"known" : @"unknown");

    __weak id weakAdapter = listAdapter;
    __weak id weakTable = tableNode;
    __weak id weakNode = node;
    __weak UIViewController *weakHost = host;
    ApolloChatRoomDirectoryResolve(subject, partner, timestamp, ^(NSString *chatPath) {
        id table = weakTable;
        UIViewController *strongHost = weakHost;
        if ([table respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(table, @selector(deselectRowAtIndexPath:animated:),
                                                       indexPath, YES);
        }
        if (!strongHost || !strongHost.viewIfLoaded.window) return;   // the list went away meanwhile
        if (!chatPath) {
            id adapter = weakAdapter;
            if (!adapter || !table) return;
            ChatsFilterLog(@"no modern Chat room matched the tapped mirror; opening Apollo's legacy thread");
            sInboxChatMirrorBypass = YES;
            ((void (*)(id, SEL, id, id))objc_msgSend)(adapter, @selector(tableNode:didSelectRowAtIndexPath:),
                                                      table, indexPath);
            sInboxChatMirrorBypass = NO;
            return;
        }
        ApolloInboxMarkMessageRead(message, weakNode, table, indexPath);
        ApolloInboxOpenChatPath(strongHost, chatPath);
    });
    return YES;
}

// Apollo's shared list adapter is the table delegate of every Texture list;
// only an InboxCellNode carrying a chat mirror is taken over here.
%hook _TtC6Apollo11ListAdapter

- (void)tableNode:(id)tableNode didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (ApolloInboxOpenChatMirrorIfNeeded(self, tableNode, indexPath)) return;
    %orig;
}

%end

// Mirrors carry the sender's account id (`author_fullname`), which RDKMessage
// drops but direct rooms are keyed by. Note it as the message JSON goes by.
static void ApolloInboxNoteMessageJSON(id json) {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *data = json;
    if ([json[@"data"] isKindOfClass:[NSDictionary class]]) {
        if (![json[@"kind"] isEqual:@"t4"]) return;
        data = json[@"data"];
    }
    if (![data[@"subject"] isKindOfClass:[NSString class]]) return;   // messages only
    ApolloChatRoomDirectoryNoteUserFullname(data[@"author"], data[@"author_fullname"]);
}

%hook MTLJSONAdapter

+ (id)modelOfClass:(Class)modelClass fromJSONDictionary:(NSDictionary *)JSONDictionary error:(NSError **)error {
    ApolloInboxNoteMessageJSON(JSONDictionary);
    return %orig;
}

+ (id)modelsOfClass:(Class)modelClass fromJSONArray:(NSArray *)JSONArray error:(NSError **)error {
    if ([JSONArray isKindOfClass:[NSArray class]]) {
        for (id json in JSONArray) ApolloInboxNoteMessageJSON(json);
    }
    return %orig;
}

%end

%ctor {
    sApolloModernChatBadgeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloModernChatStatusDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        ApolloApplyCombinedInboxBadge();
    }];
    ChatsFilterLog(@"module loaded");
}
