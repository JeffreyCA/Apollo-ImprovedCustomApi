// ApolloChatsFilter.xm
//
// Feature 2 of the chat upgrade: add a "Direct Chat" filter row to the inbox "Boxes"
// list, directly above "Messages". Tapping it opens the normal messages list but filtered
// to direct/group chats (Reddit bridges chat into private messages with the subject
// "[direct chat room]"; group chats use a "chat room" subject too).
//
// Boxes screen = _TtC6Apollo23InboxListViewController (a UITableViewController whose
// data-source methods are ObjC-visible). The "Messages" row maps to InboxType.messages and
// pushes a _TtC6Apollo19InboxViewController (inboxType=messages, messages:[RDKMessage],
// IGListKit listAdapter). We:
//   1. Detect the Messages section by the stock cell's text (layout is account-dependent).
//   2. Add one extra row at the top of that section, styled "Direct Chat".
//   3. On tap, set a one-shot flag and invoke the *real* Messages row so Apollo opens the
//      messages list normally; the flag marks that VC to filter its list to chats.
//   4. In the messages list, filter the IGListKit objects to chat-subject messages.

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloWebJSON.h" // ApolloWebJSONHasUsableSession — Direct Chat row hidden in keyless mode
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ChatsFilterLog(fmt, ...) ApolloLog(@"[ChatsFilter] " fmt, ##__VA_ARGS__)

static NSInteger sMessagesSection = -1;     // detected section index of the "Messages" row
static NSInteger sMessagesRow = -1;         // detected row index of "Messages" within that section
// "Direct Chat" Boxes row. The earlier "3 Direct Chat / Messages gone" turned out to be the tweak
// double-loading (a stale baked LC_LOAD_DYLIB + the injected copy), so EVERY hook ran twice and
// numberOfRows added +1 twice (1 real row -> 3). With a single load this inserts one row correctly.
static const BOOL sDirectChatRowEnabled = YES;
static BOOL sNextInboxIsChatFilter = NO;    // armed when the Direct Chat row is tapped
static char kChatFilterKey;                 // on InboxViewController: this list is chat-filtered

// Whether the Direct Chat row should exist for the ACTIVE account right now.
// Reddit's web JSON API omits the chat-bridge t4 messages entirely under
// cookie auth (verified live: /message/messages.json returns zero children on
// a session whose OAuth counterpart has chats), so in API-Key-Free mode the
// row would only ever open an empty list. Hide it for cookie accounts; OAuth
// accounts keep it. Re-evaluated per table callback, so it tracks account
// switches whenever the Boxes list reloads.
static BOOL ApolloDirectChatRowActive(void) {
    return sDirectChatRowEnabled && !ApolloWebJSONHasUsableSession();
}

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
                ChatsFilterLog(@"WARNING: InboxListViewController now implements %@ — the Direct Chat row shift may mis-index it; remap it too.", sel);
        }
    });
}

%hook _TtC6Apollo23InboxListViewController

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    if (ApolloDirectChatRowActive()) ApolloWarnIfUnhandledRowDelegates(self);   // one-shot future-proofing canary
    long long n = %orig;
    if (ApolloDirectChatRowActive() && sMessagesSection >= 0 && section == sMessagesSection) {
        n += 1;   // + our Direct Chat row
    }
    return n;
}

// Map a displayed row (with our inserted Direct Chat row) back to Apollo's real row in the
// Messages section. The Direct Chat row sits AT sMessagesRow (just above Messages); rows below it
// shift down by one. Returns -1 for the Direct Chat slot itself.
static NSInteger ApolloRealMessagesRow(NSInteger displayedRow) {
    if (displayedRow < sMessagesRow) return displayedRow;     // rows above Messages: unchanged
    if (displayedRow == sMessagesRow) return -1;              // our inserted Direct Chat row
    return displayedRow - 1;                                  // rows at/after Messages: shifted down
}

- (id)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDirectChatRowActive()) return %orig;   // Direct Chat row disabled / keyless — leave Boxes untouched
    // Detection pass: until we know which section/row holds "Messages", just observe.
    if (sMessagesSection < 0) {
        UITableViewCell *cell = %orig;
        NSString *text = ApolloCellText(cell);
        ChatsFilterLog(@"probe s=%ld r=%ld text=%@ cls=%@", (long)indexPath.section, (long)indexPath.row, text, NSStringFromClass([cell class]));
        if ([text isEqualToString:@"Messages"]) {
            sMessagesSection = indexPath.section;
            sMessagesRow = indexPath.row;
            ChatsFilterLog(@"Messages at s=%ld r=%ld; inserting Direct Chat row + reloading", (long)sMessagesSection, (long)sMessagesRow);
            UITableView *tv = tableView;
            dispatch_async(dispatch_get_main_queue(), ^{ [tv reloadData]; });
        }
        return cell;
    }

    if (indexPath.section == sMessagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(indexPath.row);
        if (realRow < 0) {
            // our inserted Direct Chat row: borrow the Messages cell and restyle it
            NSIndexPath *real = [NSIndexPath indexPathForRow:sMessagesRow inSection:sMessagesSection];
            UITableViewCell *cell = %orig(tableView, real);
            ChatsFilterLog(@"cellFor displayed=%ld -> DirectChat (borrow r%ld, was '%@')", (long)indexPath.row, (long)sMessagesRow, ApolloCellText(cell));
            ApolloRestyleAsDirectChat(cell);
            return cell;
        }
        // every other row maps to its real Apollo row (Messages, and anything after it)
        NSIndexPath *real = [NSIndexPath indexPathForRow:realRow inSection:sMessagesSection];
        UITableViewCell *cell = %orig(tableView, real);
        ChatsFilterLog(@"cellFor displayed=%ld -> real r%ld text='%@'", (long)indexPath.row, (long)realRow, ApolloCellText(cell));
        return cell;
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (ApolloDirectChatRowActive() && sMessagesSection >= 0 && indexPath.section == sMessagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(indexPath.row);
        if (realRow < 0) {
            ChatsFilterLog(@"Direct Chat tapped -> opening filtered messages list");
            sNextInboxIsChatFilter = YES;   // one-shot: the next InboxViewController filters to chats
            realRow = sMessagesRow;          // open the real Messages list (which we then filter)
        }
        %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:sMessagesSection]);
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
    if (ApolloDirectChatRowActive() && sMessagesSection >= 0 && indexPath.section == sMessagesSection) {
        NSInteger realRow = ApolloRealMessagesRow(indexPath.row);
        if (realRow < 0) realRow = sMessagesRow;   // Direct Chat row -> same height as the Messages row
        return %orig(tableView, [NSIndexPath indexPathForRow:realRow inSection:sMessagesSection]);
    }
    return %orig;
}

%end

#pragma mark - messages list: filter to chats

// Keep only chat-subject messages (direct + group chats both carry a "chat room" subject;
// regular PMs/modmail have a real subject, so they fall away).
static NSArray *ApolloChatFilterToChats(NSArray *messages) {
    if (![messages isKindOfClass:[NSArray class]]) return messages;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (id msg in messages) {
        NSString *subject = nil;
        if ([msg respondsToSelector:@selector(subject)])
            subject = ((NSString *(*)(id, SEL))objc_msgSend)(msg, @selector(subject));
        if (subject && [subject localizedCaseInsensitiveContainsString:@"chat room"]) [out addObject:msg];
    }
    ChatsFilterLog(@"filtered messages %lu -> %lu chats", (unsigned long)messages.count, (unsigned long)out.count);
    return out;
}

// Apollo's list is fed by a Swift Apollo.ListAdapterDataSource (not ObjC-hookable) reading the
// `messages` ivar, so we filter one level up: at the RDKClient message-inbox fetch, while the
// chat-filtered list is the visible one (sChatFilterActive). The Messages box itself never sets
// the flag, so it stays unfiltered.
static BOOL sChatFilterActive = NO;

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
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue])
        ((UIViewController *)self).title = @"Direct Chat";   // after %orig so Apollo doesn't override it
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = YES;
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, &kChatFilterKey) boolValue]) sChatFilterActive = NO;
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
    ChatsFilterLog(@"messagesInCategory cat=%lld active=%d nested=%d", category, sChatFilterActive, sChatPagingInProgress);
    if (!completion || !sChatFilterActive) return %orig;

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

%ctor {
    ChatsFilterLog(@"module loaded");
}
