// ApolloSearchNativeBar.xm
//
// Native Liquid Glass treatment for the feed / subreddit search bar (#975-style).
//
// Apollo's feed search is a custom ApolloSearchToolbar living INSIDE the feed
// ASTableView, and activating it runs a visual takeover (nav-bar hide, toolbar
// dock, inset churn) that the legacy ApolloSearchInPlace.xm spent hundreds of
// lines pinning back down. On Liquid Glass we replace all of that with the real
// thing: a UISearchController on navigationItem.searchController — UIKit renders
// the glass pill in the nav-bar palette, activates it in place (nothing moves),
// and provides the native round-glass cancel.
//
// Apollo's search *pipeline* is kept intact by bridging, not reimplementing:
// the results mode is gated solely on ASTableViewController's `isSearching`
// ivar, and the per-keystroke model update is `textFieldEditingChangedWithSender:`
// (text -> Swift vtable). So per keystroke we set isSearching, mirror the text
// into Apollo's (hidden) field, and call that handler; cancel calls Apollo's own
// `dismissSearchBarButtonTappedWithSender:`. Apollo's field never becomes first
// responder, so its takeover never fires (it lives in textFieldDidBeginEditing's
// delayed block). All verified against Apollo 1.15.11 with lldb before this was
// written.
//
// The "Keep Search Bar Visible" toggle (sKeepSearchBarInPlace) becomes literal:
// ON  -> hidesSearchBarWhenScrolling = NO (bar pinned under the nav)
// OFF -> native scroll-away + pull-to-reveal (attach visible, flip once the
//        first layout is done — the #975 recipe; plain YES on attach parks the
//        bar off-screen because these screens have no large title).
//
// Non-glass is untouched: every entry point gates on IsLiquidGlass(), and the
// legacy module keeps full ownership there.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloSearchNativeBar.h"

// Forward ref for the geometry hooks (same pattern as ApolloSearchInPlace.xm).
@interface ASTableView : UITableView
@end

@interface _TtC6Apollo21ASTableViewController : UIViewController
- (void)textFieldEditingChangedWithSender:(id)sender;
- (BOOL)textFieldShouldReturn:(id)textField;
- (void)dismissSearchBarButtonTappedWithSender:(id)sender;
@end

// Runtime ivar reader; walks the superclass chain so inherited ivars resolve.
// (Deliberately duplicated per-module, matching the repo's existing pattern.)
static id ApolloNSBObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static BOOL ApolloNSBReadBoolIvar(id object, const char *name, BOOL *outValue) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NO;
    *outValue = *(BOOL *)((char *)(__bridge void *)object + ivar_getOffset(ivar));
    return YES;
}

static BOOL ApolloNSBWriteBoolIvar(id object, const char *name, BOOL value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NO;
    *(BOOL *)((char *)(__bridge void *)object + ivar_getOffset(ivar)) = value;
    return YES;
}

// MARK: - Session state
//
// Only one feed search is ever active at a time; the session is keyed to the
// controller whose native bar last began editing. Everything is __weak so a
// popped controller degrades to "no session" with no teardown bookkeeping.
static __weak UIViewController *sNSBSessionVC    = nil;
static __weak UIScrollView     *sNSBSessionTable = nil;
static __weak UINavigationBar  *sNSBSessionNav   = nil;
static BOOL sNSBSessionTyped   = NO;
static BOOL sNSBTransitioning  = NO;  // feed VC is disappearing (push/pop in flight)  // Apollo's isSearching was engaged (needs a real dismiss)
static BOOL sNSBUserScrolled   = NO;  // user dragged the results — stop pinning so they can browse

static const void *kNSBBridgeKey     = &kNSBBridgeKey;      // VC -> bridge delegate object
static const void *kNSBFeedTableKey  = &kNSBFeedTableKey;   // ASTableView -> @YES (native-managed feed)
static CGFloat sNSBToolbarBand = 45.0; // Apollo's resting toolbar height (the band its inset reserves)

BOOL ApolloNativeFeedSearchEnabled(void) {
    return IsLiquidGlass();
}

static NSString *NSBSessionQueryText(void) {
    UIViewController *vc = sNSBSessionVC;
    if (!vc) return nil;
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(vc, "searchTextField");
    return [field isKindOfClass:[UITextField class]] ? field.text : nil;
}

BOOL ApolloNativeFeedSearchActiveQuery(UIScrollView *tableView) {
    return ApolloNativeFeedSearchEnabled() && tableView != nil &&
           tableView == sNSBSessionTable && sNSBSessionTyped &&
           NSBSessionQueryText().length > 0;
}

// A feed controller we manage: an ASTableViewController with Apollo's search
// toolbar, excluding the comments in-thread search (stick-to-keyboard layout).
static BOOL NSBIsNativeSearchFeedVC(UIViewController *vc) {
    if (![vc isKindOfClass:objc_getClass("_TtC6Apollo21ASTableViewController")]) return NO;
    BOOL stick = NO;
    if (ApolloNSBReadBoolIvar(vc, "searchBarShouldStickToKeyboard", &stick) && stick) return NO;
    return ApolloNSBObjectIvar(vc, "upperToolbar") != nil &&
           ApolloNSBObjectIvar(vc, "searchTextField") != nil;
}

static UIScrollView *NSBTableForVC(UIViewController *vc) {
    id tableNode = ApolloNSBObjectIvar(vc, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    return [tv isKindOfClass:objc_getClass("ASTableView")] ? (UIScrollView *)tv : nil;
}

static UIViewController *NSBFeedVCForView(UIView *view) {
    UIResponder *r = view.nextResponder;
    int guard = 0;
    while (r && guard++ < 40) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// MARK: - Driving Apollo's pipeline

static void NSBDriveApolloQuery(UIViewController *vc, NSString *text) {
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(vc, "searchTextField");
    if (![field isKindOfClass:[UITextField class]]) return;
    ApolloNSBWriteBoolIvar(vc, "isSearching", YES);
    sNSBSessionTyped = YES;
    if (![field.text isEqualToString:(text ?: @"")]) field.text = text ?: @"";
    if ([vc respondsToSelector:@selector(textFieldEditingChangedWithSender:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(textFieldEditingChangedWithSender:), field);
    }
}

static void NSBRestoreHeaderForTable(UIScrollView *sv);

static NSUInteger sNSBDismissGen = 0; // stale-timer guard for the settle snap

static void NSBApolloDismiss(UIViewController *vc) {
    if (!vc) return;
    UIScrollView *table = NSBTableForVC(vc);
    // Clear the session BEFORE Apollo's dismiss so our geometry pins are inert
    // and Apollo's own restore (offset/inset re-park) runs stock — verified clean.
    sNSBSessionTyped = NO;
    sNSBUserScrolled = NO;
    if (table) NSBRestoreHeaderForTable(table);
    id field = ApolloNSBObjectIvar(vc, "searchTextField");
    if ([vc respondsToSelector:@selector(dismissSearchBarButtonTappedWithSender:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(dismissSearchBarButtonTappedWithSender:), field);
    }
    ApolloNSBWriteBoolIvar(vc, "isSearching", NO);

    // Apollo's dismiss re-parks the offset for ITS resting inset (toolbar band
    // included), which leaves the feed a few rows' worth low against the native
    // rest. Once the dismiss animation settles, snap a near-top rest back flush.
    // Two checks because the re-park lands at slightly different times.
    NSUInteger gen = ++sNSBDismissGen;
    __weak UIScrollView *weakTable = table;
    void (^settle)(void) = ^{
        UIScrollView *sv = weakTable;
        if (!sv || gen != sNSBDismissGen || sNSBSessionTyped) return;
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) return;
        CGFloat rest = -sv.contentInset.top;
        CGFloat y = sv.contentOffset.y;
        // Unbounded above: a surfaced subreddit search parks hundreds of points
        // down (header height); dismiss always returns to the resting top, the
        // same restore the legacy teardown clamp performed.
        if (y > rest + 1.0) [sv setContentOffset:CGPointMake(0.0, rest) animated:NO];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), settle);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), settle);
}

// MARK: - Results surfacing (subreddit chrome)
//
// Same behavior the legacy module shipped for #534, re-anchored: while a query
// is live, a subreddit's full header (banner + description + Community
// Highlights — Reborn's ApolloSubredditHeaderWrapperView) is scrolled off the
// top so the first results row sits right under the bar, and the header view is
// alpha-hidden so the scrolled-up chrome doesn't bleed through the glass.

static BOOL NSBManagedHeader(UIScrollView *sv) {
    UIView *hdr = [sv respondsToSelector:@selector(tableHeaderView)] ? [(UITableView *)sv tableHeaderView] : nil;
    return [hdr isMemberOfClass:objc_getClass("ApolloSubredditHeaderWrapperView")];
}

static CGFloat NSBDesiredOffsetY(UIScrollView *sv) {
    CGFloat rest = -sv.contentInset.top; // contentInsetAdjustmentBehavior == Never on the feed
    if (!NSBManagedHeader(sv)) return rest;
    if (NSBSessionQueryText().length == 0) return rest;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat height = CGRectGetHeight(hdr.frame);
    if (height <= 1.0) return rest;
    CGFloat surfaced = height - sv.contentInset.top;
    return surfaced > rest ? surfaced : rest;
}

static BOOL NSBIsSurfaced(UIScrollView *sv) {
    if (!sv || sv != sNSBSessionTable || !sNSBSessionTyped || sNSBUserScrolled) return NO;
    if (NSBSessionQueryText().length == 0) return NO;
    return NSBDesiredOffsetY(sv) > (-sv.contentInset.top + 1.0);
}

static void NSBSetHeaderHidden(UIScrollView *sv, BOOL hidden) {
    if (!NSBManagedHeader(sv)) return;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat a = hidden ? 0.0 : 1.0;
    if (hdr.alpha != a) hdr.alpha = a;
}

static void NSBRestoreHeaderForTable(UIScrollView *sv) {
    if (sv) NSBSetHeaderHidden(sv, NO);
}

// MARK: - Bridge delegate

@interface ApolloNativeSearchBridge : NSObject <UISearchBarDelegate, UISearchControllerDelegate>
@property (nonatomic, weak) UIViewController *feedVC;
@end

@implementation ApolloNativeSearchBridge

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    sNSBSessionVC = vc;
    sNSBSessionTable = NSBTableForVC(vc);
    sNSBSessionNav = vc.navigationController.navigationBar;
    sNSBUserScrolled = NO;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    // An empty change with the field unfocused is one of two very different
    // things. During a push/pop transition it is UIKit clearing the bar as a
    // side effect of deactivating the search UI — ignore it, or it would wipe
    // the results the user is navigating into. At rest it is the user tapping
    // the bar's clear button on a restored query — that means "end the search".
    if (searchText.length == 0 && !searchBar.isFirstResponder) {
        if (!sNSBTransitioning && sNSBSessionTyped) NSBApolloDismiss(vc);
        return;
    }
    sNSBSessionVC = vc;
    if (!sNSBSessionTable) sNSBSessionTable = NSBTableForVC(vc);
    NSBDriveApolloQuery(vc, searchText);
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Mirror Apollo's return-key behavior (runs the full server search).
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    id field = ApolloNSBObjectIvar(vc, "searchTextField");
    if ([vc respondsToSelector:@selector(textFieldShouldReturn:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(textFieldShouldReturn:), field);
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    // The explicit cancel is the ONLY place we end Apollo's session. A nav push
    // may deactivate the UIKit search UI without cancel — the results must
    // survive that so returning from a result keeps the search, like today.
    UIViewController *vc = self.feedVC;
    if (searchBar.text.length > 0) searchBar.text = @"";
    if (sNSBSessionTyped) NSBApolloDismiss(vc);
}

@end

// MARK: - Attach / policy

static void NSBAttachNativeSearch(UIViewController *vc) {
    UINavigationItem *navItem = vc.navigationItem;
    if (navItem.searchController != nil) return; // ours (or someone's) — never fight it

    ApolloNativeSearchBridge *bridge = objc_getAssociatedObject(vc, kNSBBridgeKey);
    if (!bridge) {
        bridge = [[ApolloNativeSearchBridge alloc] init];
        bridge.feedVC = vc;
        objc_setAssociatedObject(vc, kNSBBridgeKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.obscuresBackgroundDuringPresentation = NO; // results render in the feed itself
    // Keep the nav bar (title + buttons) while the search is active — the whole
    // point of this treatment is that activation moves nothing. It also removes
    // the fragile hide/restore dance across result pushes (a hidden nav bar
    // could come back unrestored after an interactive pop).
    sc.hidesNavigationBarDuringPresentation = NO;
    sc.delegate = bridge;
    sc.searchBar.placeholder = @"Search";
    sc.searchBar.delegate = bridge;
    UIColor *accent = ApolloThemeAccentColor();
    if (accent) sc.searchBar.tintColor = accent;

    if (@available(iOS 16.0, *)) {
        // iPhone stacks by default; force it on iPad too so the bar keeps the
        // under-the-title placement instead of jumping to the trailing edge.
        if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            navItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
        }
    }

    // Attach laid-out-visible; the scroll-away policy flips it after the first
    // appearance (plain YES here parks the bar off-screen — no large title).
    navItem.searchController = sc;
    navItem.hidesSearchBarWhenScrolling = NO;

    // Point UIKit's bar collapse tracking at the actual feed table — automatic
    // detection lands on Apollo's full-screen intercepting scroll view, which
    // never scrolls, so the bar would never collapse.
    UIScrollView *table = NSBTableForVC(vc);
    if (table) {
        objc_setAssociatedObject(table, kNSBFeedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (@available(iOS 15.0, *)) {
            [vc setContentScrollView:table forEdge:NSDirectionalRectEdgeTop];
        }
    }
    ApolloLog(@"[NativeSearch] attached search controller to %s", object_getClassName(vc));
}

// Hide Apollo's own toolbar (the resting pill inside the feed). Re-asserted
// every layout pass — Apollo can recreate or re-show it across reloads.
static void NSBHideApolloToolbar(UIViewController *vc) {
    UIView *toolbar = (UIView *)ApolloNSBObjectIvar(vc, "upperToolbar");
    if (![toolbar isKindOfClass:[UIView class]]) return;
    CGFloat h = CGRectGetHeight(toolbar.bounds);
    if (h > 1.0 && h < 100.0) sNSBToolbarBand = h;
    if (!toolbar.hidden) toolbar.hidden = YES;
}

// Nav-bar bottom (including the search palette, which is part of the bar's
// frame) measured in the table's frame space — the value contentInset.top must
// clear for content to rest below the bar.
static CGFloat NSBNavBottomForTable(UIScrollView *table, UIViewController *vc) {
    UINavigationBar *nav = vc.navigationController.navigationBar;
    if (!nav || !nav.window || !table.window) return 0.0;
    CGFloat navBottomW = CGRectGetMaxY([nav convertRect:nav.bounds toView:nil]);
    CGFloat tableTopW = [table.superview convertPoint:table.frame.origin toView:nil].y;
    return navBottomW - tableTopW;
}

%hook _TtC6Apollo21ASTableViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    NSBAttachNativeSearch((UIViewController *)self);
    NSBHideApolloToolbar((UIViewController *)self);
    // Returning to a live search (e.g. back from an opened result): keep the
    // native bar's text in step with Apollo's field so the query stays visible.
    UINavigationItem *navItem = [(UIViewController *)self navigationItem];
    UISearchBar *bar = navItem.searchController.searchBar;
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UITextField class]] && field.text.length > 0) {
        if (![bar.text isEqualToString:field.text]) bar.text = field.text;
        // Returning to a live query: Apollo's restore re-applies its
        // search-active layout (nav-bar transform/alpha hide) straight from
        // isSearching — no focus involved — so arm the whole session (including
        // typed, which a cancel in a DIFFERENT feed may have cleared globally)
        // before it runs.
        sNSBSessionVC = (UIViewController *)self;
        sNSBSessionTable = NSBTableForVC((UIViewController *)self);
        sNSBSessionNav = [(UIViewController *)self navigationController].navigationBar;
        sNSBSessionTyped = YES;
    }
}


- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    sNSBTransitioning = NO;
    UINavigationItem *navItem = [(UIViewController *)self navigationItem];
    if (!navItem.searchController) return;
    // Scroll-away policy. Flipped here, after the first layout, so the bar is
    // never parked off-screen on arrival (#975's lesson). "Keep Search Bar
    // Visible" pins it; otherwise it collapses with the scroll and a pull at
    // the top reveals it again.
    BOOL wantScrollAway = !sKeepSearchBarInPlace;
    if (navItem.hidesSearchBarWhenScrolling != wantScrollAway) {
        navItem.hidesSearchBarWhenScrolling = wantScrollAway;
    }
    // Safety net for the return-to-live-query path: if Apollo's search-active
    // layout hid the nav bar before the guard armed, put it back.
    UINavigationBar *nav = [(UIViewController *)self navigationController].navigationBar;
    if (sNSBSessionTyped && nav && nav == sNSBSessionNav) {
        if (nav.transform.ty < -1.0) nav.transform = CGAffineTransformIdentity;
        if (nav.alpha < 1.0) nav.alpha = 1.0;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    sNSBTransitioning = YES;
    // Leaving the feed (e.g. opening a result) with the search UI presented:
    // deactivate it cleanly. Keeping it active across a push leaves UIKit's
    // presentation half-restored after the pop (missing nav bar, collapsed
    // inset). Apollo's query/results live on the VC, not on the controller, so
    // nothing is lost — viewWillAppear re-syncs the bar text on return.
    UISearchController *sc = [(UIViewController *)self navigationItem].searchController;
    if (sc.active) sc.active = NO;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    // The toolbar/field ivars can be nil on the very first willAppear; attach
    // lazily here too (idempotent — bails once a searchController exists).
    NSBAttachNativeSearch((UIViewController *)self);
    NSBHideApolloToolbar((UIViewController *)self);
    UIScrollView *table = NSBTableForVC((UIViewController *)self);
    if (table && table == sNSBSessionTable) {
        NSBSetHeaderHidden(table, NSBIsSurfaced(table));
    }
}

%end

// MARK: - Apollo's field must never take focus
//
// Apollo re-focuses its own field when restoring a search on return-to-feed
// (becomeFirstResponder -> textFieldShouldBeginEditing reparents the toolbar +
// the didBeginEditing block runs the takeover). With the native bar installed
// that whole path must stay dark — the field is a hidden model object only.
%hook _TtC6Apollo24ApolloSearchBarTextField

- (BOOL)becomeFirstResponder {
    if (ApolloNativeFeedSearchEnabled()) {
        UIViewController *vc = NSBFeedVCForView((UIView *)self);
        if (vc && NSBIsNativeSearchFeedVC(vc) &&
            vc.navigationItem.searchController != nil &&
            objc_getAssociatedObject(vc, kNSBBridgeKey) != nil) {
            return NO;
        }
    }
    return %orig;
}

%end

// MARK: - Feed geometry
//
// Inset: floor the feed's top inset to the nav bar's bottom (which includes the
// expanded search palette) so content rests below the native bar. A floor, not
// an exact set: Apollo grows the inset for pull-to-refresh, and when the bar
// collapses (scroll-away) the nav bottom shrinks below Apollo's own resting
// inset and the floor becomes a no-op — self-correcting in both directions.
//
// Offset: while a query is live, clamp Apollo's programmatic re-parks so the
// results stay put (and, with a full subreddit header, hold the chrome scrolled
// off the top). Released the instant the user drags; re-armed at the top.
// bounds.origin IS contentOffset and Texture re-parks through setBounds: too —
// both setters carry the pin or it doesn't hold (#534's key lesson).
%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (ApolloNativeFeedSearchEnabled() &&
        objc_getAssociatedObject(self, kNSBFeedTableKey) != nil) {
        UIViewController *vc = NSBFeedVCForView((UIView *)self);
        if (vc) {
            // Apollo's inset formula tracks the safe area (which now includes the
            // search palette) but still reserves the band for its own — hidden —
            // toolbar. Remove that dead band; Apollo's formula then follows the
            // palette expanding/collapsing on its own. Floor at the nav bottom so
            // content can never rest under the bar; growth beyond the resting
            // shape (pull-to-refresh spinner) passes through untouched.
            CGFloat want = NSBNavBottomForTable((UIScrollView *)self, vc);
            if (inset.top > sNSBToolbarBand) {
                inset.top -= sNSBToolbarBand;
                if (want > 1.0 && inset.top < want) inset.top = want;
            }
        }
    }
    %orig(inset);
}

- (void)setContentOffset:(CGPoint)offset {
    UIScrollView *sv = (UIScrollView *)self;
    if (ApolloNativeFeedSearchEnabled() && sv == sNSBSessionTable &&
        sNSBSessionTyped && NSBSessionQueryText().length > 0) {
        CGFloat target = NSBDesiredOffsetY(sv);
        if (sv.isDragging) sNSBUserScrolled = YES;
        else if (offset.y <= target + 1.0) sNSBUserScrolled = NO;
        if (!sv.isDragging && !sv.isDecelerating && !sNSBUserScrolled) {
            if (NSBManagedHeader(sv) && target > -sv.contentInset.top + 1.0) {
                offset.y = target;          // surfaced: chrome held off the top
            } else if (offset.y > target) {
                offset.y = target;          // clamp keystroke re-parks; keep pull-to-refresh
            }
        }
        NSBSetHeaderHidden(sv, NSBIsSurfaced(sv));
    }
    %orig(offset);
}

- (void)setBounds:(CGRect)bounds {
    UIScrollView *sv = (UIScrollView *)self;
    if (ApolloNativeFeedSearchEnabled() && sv == sNSBSessionTable &&
        !sv.isDragging && !sv.isDecelerating && NSBIsSurfaced(sv)) {
        CGFloat want = NSBDesiredOffsetY(sv);
        if (fabs(bounds.origin.y - want) > 0.5) bounds.origin.y = want;
        NSBSetHeaderHidden(sv, YES);
    }
    %orig(bounds);
}

- (void)setTableHeaderView:(UIView *)header {
    %orig;
    UIScrollView *sv = (UIScrollView *)self;
    if (header && ApolloNativeFeedSearchEnabled() && NSBIsSurfaced(sv)) {
        NSBSetHeaderHidden(sv, YES);
    }
}

%end

// The subreddit header wrapper force-restores its own alpha in layoutSubviews
// (anti-flash); hold it hidden while the native session has it surfaced.
// (ApolloSearchInPlace.xm has the same hook for the legacy session — both
// gates are session-scoped, so at most one ever fires.)
@interface ApolloSubredditHeaderWrapperView : UIView
@end

%hook ApolloSubredditHeaderWrapperView

- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.0 && sNSBSessionTable &&
        (UIView *)self == [(UITableView *)sNSBSessionTable tableHeaderView] &&
        NSBIsSurfaced(sNSBSessionTable)) {
        %orig(0.0);
        return;
    }
    %orig;
}

%end

// MARK: - Nav-bar guard (session-scoped)
//
// Apollo's search-active layout hides the nav bar with a transform + fade. With
// the native bar that must never happen — the treatment's whole premise is the
// nav stays put — and the hide can arrive WITHOUT any focus event (the
// return-to-feed restore applies it straight from isSearching). Block it for
// the session's bar only, while a query is live; every other nav bar (and the
// Hide Bars on Scroll feature outside a search) passes through untouched.
// (ApolloSearchInPlace.xm has the same hooks for the legacy session; its
// captured bar stays nil while the native system owns glass, so only one of
// the two ever acts.)
%hook UINavigationBar

- (void)setTransform:(CGAffineTransform)transform {
    if (ApolloNativeFeedSearchEnabled() && self == sNSBSessionNav &&
        sNSBSessionTyped && transform.ty < -1.0) {
        %orig(CGAffineTransformIdentity);
        return;
    }
    %orig;
}

- (void)setAlpha:(CGFloat)alpha {
    if (ApolloNativeFeedSearchEnabled() && self == sNSBSessionNav &&
        sNSBSessionTyped && alpha < 1.0) {
        %orig(1.0);
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
}
