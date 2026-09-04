#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <Security/SecBase.h>

// On iOS 26, NSLog redacts strings, so use os_log: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes#NSLog
// Uses a dedicated subsystem so OSLogStore can efficiently filter our entries.
#define ApolloLogWithType(type, fmt, ...) do { \
    NSString *logMessage = [NSString stringWithFormat:@"[ApolloFix] " fmt, ##__VA_ARGS__]; \
    os_log_with_type(ApolloFixLog(), type, "%{public}s", [logMessage UTF8String]); \
} while(0)
#define ApolloLog(fmt, ...) ApolloLogWithType(OS_LOG_TYPE_DEFAULT, fmt, ##__VA_ARGS__)
#define ApolloLogDebug(fmt, ...) ApolloLogWithType(OS_LOG_TYPE_DEBUG, fmt, ##__VA_ARGS__)

__BEGIN_DECLS
os_log_t ApolloFixLog(void);
NSString *ApolloCollectLogs(void);

// --- Row-measure re-entrancy guard (issues #831/#833/#838/#839/#841) ---
// Main-thread depth of UITableView row-height passes currently on the stack
// (maintained by the ASTableView tableView:heightForRowAtIndexPath: hook in
// ApolloInlineLinkPreviews.xm). While a pass is in progress, UIKit is inside
// its row-data (re)validation (-[UISectionRowData refreshWithSection:...] /
// endUpdates); calling ANY UITableView geometry query (indexPathForCell:,
// rectForRowAtIndexPath:, indexPathsForVisibleRows, ...) from tweak code at
// that moment makes UIKit start a NESTED full-section validation — one extra
// ~48-frame nesting level per row — until the main thread's 1MB stack
// overflows (EXC_BAD_ACCESS on a stack-guard address, crashing whatever
// innocent code runs at the boundary). Any tweak code that can run inside a
// row measure (layoutSpecThatFits:, text-setter hooks, ...) must check
// ApolloRowMeasureInProgress() before touching table geometry and decline or
// defer instead.
BOOL ApolloRowMeasureInProgress(void);
void ApolloRowMeasureWillBegin(void);
void ApolloRowMeasureDidEnd(void);
NSString *ApolloCollectAILogs(void);

// One-shot immutable Security dictionaries for the generic-password shapes
// shared by the tweak. Callers own the returned dictionary.
CFDictionaryRef ApolloCreateGenericPasswordIdentity(CFStringRef service,
                                                     CFStringRef account) CF_RETURNS_RETAINED;
CFDictionaryRef ApolloCreateGenericPasswordDataQuery(CFStringRef service,
                                                      CFStringRef account) CF_RETURNS_RETAINED;
OSStatus ApolloUpsertGenericPasswordData(CFStringRef service,
                                         CFStringRef account,
                                         NSData *data,
                                         CFStringRef accessible);

// Starts a data request whose response is bounded before and during transfer.
// HTTP errors and an advertised/actual body larger than maximumBytes fail the
// task. responseValidator may reject a 2xx response (for example by MIME type)
// before any bytes are accepted. Completion is delivered exactly once on
// completionQueue (the main queue when nil), including cancellation.
typedef NSError *(^ApolloBoundedDataResponseValidator)(NSHTTPURLResponse *response);
typedef void (^ApolloBoundedDataCompletion)(NSData *data,
                                            NSHTTPURLResponse *response,
                                            NSError *error);
NSURLSessionDataTask *ApolloStartBoundedDataRequest(
    NSURLRequest *request,
    NSUInteger maximumBytes,
    ApolloBoundedDataResponseValidator responseValidator,
    dispatch_queue_t completionQueue,
    ApolloBoundedDataCompletion completion);

BOOL IsLiquidGlass(void);

// --- Liquid Glass trailing-cluster reservation ---
// Some screens temporarily strip their right bar buttons while staying on the
// SAME navigation item (the Inbox strips them whenever its in-place Chat hub
// covers Notifications). The Liquid Glass title recenter in
// ApolloLiquidGlass.xm would then re-balance the title against an empty
// trailing side, visibly sliding it — in gap-centering mode because the gap
// midpoint moves, and in screen-centering mode because the overlap clamp
// relaxes. While a "hold" is set on the navigation item, the recenter keeps
// using the trailing content edge it last measured for that item (stored as an
// inset from the bar's trailing edge, so rotation keeps working), making the
// title position identical whether the buttons are up or stripped. The
// recenter itself records the live inset via
// ApolloNavItemNoteTrailingContentInset on every pass that sees real trailing
// content; holders only toggle the hold. All four are no-ops off-glass (the
// recenter never runs there and nothing else reads the values).
void ApolloNavItemSetTrailingReservationHold(UINavigationItem *item, BOOL hold);
BOOL ApolloNavItemTrailingReservationHold(UINavigationItem *item);
void ApolloNavItemNoteTrailingContentInset(UINavigationItem *item, CGFloat inset);
CGFloat ApolloNavItemTrailingContentInset(UINavigationItem *item);   // 0 = never captured
NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url);
BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL);
void ApolloFlushReadPostIDsToDefaults(void);
UITableView *ApolloInheritedSettingsThemeSourceTableView(UITableViewController *controller);
void ApolloApplyInheritedSettingsTableTheme(UITableViewController *controller);

// YES if sourceTable is nil or detached from its window. A covered (non-
// topmost) nav stack screen stops getting traitCollectionDidChange:, so its
// cells' colors can be stale — callers sampling a cell's color from an
// inherited source table should check this before trusting the sample.
BOOL ApolloThemeSourceTableIsStale(UITableView *sourceTable);
UIImage *ApolloEmojiSettingsIcon(NSString *emoji, UIColor *backgroundColor, CGFloat size);
UIImage *ApolloBuyMeACoffeeSettingsIcon(CGFloat size);
UIImage *ApolloRebornOptionsSettingsIcon(CGFloat size);

// Baseline-aligned SF Symbol as an attributed string, sized to `font` and
// tinted `tint`. Returns nil if the symbol can't load, so callers can fall
// back to a plain-text glyph. Shared by ApolloAISummary.xm/ApolloPollVoting.xm.
NSAttributedString *ApolloSymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint);

// Resolve a path to a bundled tweak resource across the install layouts we
// support (jailbreak rootful/rootless, Sideloadly/cyan/azule deb fuse, and
// inject-deb-local.sh). Returns nil if no layout has the file.
NSString *ApolloBundledResourcePath(NSString *baseName, NSString *extension);

// Renders a bundled single-page PDF (`baseName`.pdf in Resources/) into a
// template UIImage at the device scale, so contributed vector icons stay crisp
// on every screen instead of shipping as fixed-scale PNGs. `maxSize` bounds the
// result while preserving aspect ratio; pass CGSizeZero for the PDF's natural
// size. Results are cached per name+size. Returns nil when the resource isn't
// staged in this install layout, so callers can fall back to an SF Symbol.
UIImage *ApolloBundledPDFTemplateImage(NSString *baseName, CGSize maxSize);

// Monotonic milliseconds (CACurrentMediaTime-based); ~ns-cheap. Used by the
// trailing-debounce relayout schedulers (InlineImages, LinkPreviews).
double ApolloPerfNowMs(void);

// The build variant string sent with the anonymous usage heartbeat, e.g.
// "glass", "deb-rootless". The source of truth is stamped at package time (IPA
// variants set Info.plist "ARBuildVariant"; .deb installs drop an "ARVariant.txt"
// resource). Falls back to "unknown" when no marker is present (dev builds).
NSString *ApolloBuildVariant(void);

// Returns YES when a link-card title is a numeric-ID-style junk string —
// contains at least one digit but no letters at all (e.g. the scraped
// "285023 289273 400021448" title from a single-page-app page). Used to decide
// when to substitute a website name for an unhelpful machine-scraped title.
BOOL ApolloIsJunkNumericTitle(NSString *title);

// Derives a presentable website name from a host ("fifa.com" -> "FIFA",
// "news.bbc.co.uk" -> "BBC", "theverge.com" -> "Theverge"). Short registrable
// labels are uppercased as acronyms; longer ones are title-cased. Returns nil
// when no usable name can be derived (e.g. a raw IP host).
NSString *ApolloWebsiteNameFromHost(NSString *host);

// Returns the URL string a LinkButtonNode is presenting, by reading either
// the obj-c .url getter (older iOS) or the urlTextNode's attributed text
// (iOS 26+ where the Swift URL ivar is no longer ObjC-bridged). May return
// nil if neither path yields a usable string.
NSString *ApolloGetLinkButtonNodeURLString(id linkButtonNode);
void ApolloPresentWebURLFromViewController(UIViewController *presenter, NSURL *url);
// Route a reddit URL through Apollo's own AppDelegate URL handler (native post/
// subreddit/user views). Returns NO if the handler is unavailable — fall back to
// ApolloPresentWebURLFromViewController.
BOOL ApolloRouteURLThroughApp(NSURL *url);

// Returns all UIWindows across every connected UIWindowScene.
// Use instead of the deprecated UIApplication.windows property.
NSArray<UIWindow *> *ApolloAllWindows(void);
// Re-centers every live nav bar title after the LG title-centering mode toggle
// changes (defined in ApolloLiquidGlass.xm; no-op off Liquid Glass).
void ApolloLGTitleCenteringModeChanged(void);
// Keeps the Liquid Glass title capsule in sync with a custom title view's
// independently-faded content (defined in ApolloLiquidGlass.xm; no-op off LG).
void ApolloNavigationTitleGlassSetContentAlpha(UIView *contentView, CGFloat alpha);

// Apollo's main ApolloTabBarController, found via the scene/app delegate's
// tabBarController ivar or by walking window root VCs. Returns nil while the
// UI is still coming up (e.g. cold launch from a URL) — callers should retry.
UIViewController *ApolloMainTabBarController(void);

// Scene-scoped form for actions that originate from a UIScene callback or a
// view already attached to a window. Passing nil uses the same deterministic
// foreground/key-scene selection as ApolloMainTabBarController().
UIViewController *ApolloMainTabBarControllerForScene(UIWindowScene *scene);

// The navigation controller holding a tab's root stack.
//
// In the stock layout this is the identity function — a UITabBarController's
// child IS the navigation controller. With the experimental iPad pane layout
// active (src/ipad/), that child is a UISplitViewController instead, and this
// unwraps it to the primary column's navigation controller.
//
// Use this anywhere you would have written `tabBarController.viewControllers[i]`
// or `tabBarController.selectedViewController` and then cast to
// UINavigationController. Returns nil when there is no navigation controller to
// find. Safe on iPhone, where it can only ever take the identity path.
UINavigationController *ApolloNavigationControllerForTabChild(UIViewController *child);

// Every navigation controller inside a tab child, primary column first: one
// element in the stock layout, up to two with the pane layout. For callers that
// WALK stacks looking for a particular controller, rather than picking one to
// push onto — those would otherwise miss whatever sits in the detail column.
NSArray<UINavigationController *> *ApolloAllNavigationControllersForTabChild(UIViewController *child);

// The column a "what is the user looking at" walk should descend into.
//
// Every recursive visible-controller finder in the tweak knows how to unwrap a
// navigation controller and a tab bar controller; without this, a split view
// controller falls through and the walk stops on the container itself, which is
// never a content screen. Returns the detail column when it holds real content,
// otherwise the primary column.
//
// ApolloCommon deliberately does not import src/ipad/: the pane controller
// answers `apollo_preferredContentColumnController`, and this falls back to a
// positional lookup for any other split view controller.
UIViewController *ApolloContentColumnForSplitViewController(UISplitViewController *split);

// YES when `ancestor` is `descendant`, or contains it anywhere in its view
// controller containment tree.
BOOL ApolloViewControllerContains(UIViewController *ancestor, UIViewController *descendant);

// Selects the tab that contains `descendant`, and returns whether one was found.
//
// Use instead of assigning `tabBarController.selectedViewController` directly
// whenever the controller you have is a navigation controller you found inside
// a tab. In the stock layout the tab's child IS that navigation controller, so
// the two are equivalent; under the iPad pane layout the child is a split view
// controller and the direct assignment silently does nothing, because the
// navigation controller is no longer in `viewControllers`.
BOOL ApolloSelectTabContainingViewController(UITabBarController *tabBarController,
                                             UIViewController *descendant);

// Returns YES for Apple's out-of-process share/compose controllers that the
// tweak must never traverse or mutate. Their class names end in
// "ComposeViewController" (e.g. MFMessageComposeViewController), so loose
// suffix matchers misidentify them as Apollo composers and crash when the
// GIF/composer machinery pokes at the remote view hierarchy (issue #366).
// Resolved via objc_getClass so we don't link MessageUI/Social.
BOOL ApolloIsSystemShareComposeController(UIViewController *controller);

// Present the tweak's fullscreen zoomable image-album viewer (implemented in
// ApolloInlineImages). Items are dictionaries with an @"url" NSURL; despite
// the name it is a generic viewer, not ImageChest-specific. Returns NO when
// items is empty or no presenter could be found from sourceView.
BOOL ApolloPresentImageChestItems(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex);
// As above, but albumURL is the album's page URL when known — it enables the
// viewer's "Share Album Link" action; pass nil otherwise.
BOOL ApolloPresentImageChestItemsWithAlbumURL(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex, NSURL *albumURL);

// Convert between a UIColor and a 6-digit "RRGGBB" hex string. The parser
// tolerates an optional leading '#'; it returns nil for anything that isn't
// exactly six hex digits. The serializer emits uppercase, no '#'. Shared by
// the link-preview card color picker and any other free-form color UI.
UIColor *ApolloColorFromHexString(NSString *hex);
NSString *ApolloHexStringFromColor(UIColor *color);

// Returns YES when a fill color is light enough that dark (black) text reads
// better on top of it than white. Uses Rec.601 luminance. Used to auto-contrast
// the link-preview card text against an arbitrary user-picked card color.
BOOL ApolloColorIsLight(UIColor *color);

// Maps a legacy ApolloLinkPreviewCardColor preset enum value to its UIColor.
// Retained only to migrate a pre-existing preset selection into the new
// free-form hex color the first time a user runs a build with the picker.
UIColor *ApolloLinkPreviewPresetColor(NSInteger preset);

// Packs a hex color into the render-safe snapshot format used by
// sLinkPreviewCardColorPacked: 0 for nil/invalid/empty, otherwise
// (1<<24) | (R<<16) | (G<<8) | B.
uint32_t ApolloPackedColorFromHexString(NSString *hex);

// Canonical setter for the link-preview card color. Normalizes `hex` (nil for
// invalid/empty = Default) and updates BOTH sLinkPreviewCardColorHex (the
// main-thread NSString used by UI/persistence) and the render-safe packed
// snapshot for the renderer. Call on the main thread.
void ApolloSetLinkPreviewCardColorHex(NSString *hex);

// Whether the experimental native Polls feature (voting + creation) is enabled.
// Off by default; toggled from Settings → Polls (UDKeyPollsEnabled). All poll
// entry points — the poll-node tap handler, remembered-vote reconciliation, the
// compose "Poll" post type, and the quick-menu Poll entry — gate on this, so
// with it off the tweak leaves Apollo's stock behavior completely untouched.
BOOL ApolloPollsFeatureEnabled(void);

// ApolloPollCompose: quick post-type picker for the subreddit "..." menu.
// Returns an inline UIMenu (ControlGroup-style icon row: Photo/Link/Text/Poll,
// filtered by the current subreddit's submission rules) that replaces the
// plain "Submit Post" row, or nil to keep the stock row. `selectRow` re-fires
// the original Submit Post action; the tapped type is applied to the compose
// sheet's segmented control when it appears. Called from
// ApolloNativeActionMenuBuildMenu when it hits actionKind 51 (Submit Post).
UIMenu *ApolloSubmitPostTypesMenu(id actionController, void (^selectRow)(void));

// Container keychain mirror (Tweak.xm): the Valet items the real keychain could not persist
// on a keychain-broken sideload, so a backup taken there still carries the signed-in account.
// Returns an array of { "service", "account", "data" } dicts (empty when the mirror is dormant).
NSArray<NSDictionary *> *ApolloKeychainMirrorItemsForBackup(void);

// Append a login-persistence diagnostic line to the cross-launch buffer in the app container.
// Mirrors the line into a file that survives force-quit, so Export Debug Logs carries the
// session that actually signed the user out. Safe to call from any thread; never logs secrets.
void ApolloAppendLoginDiag(NSString *line);

// Append an iOS 27 list/tab-bar geometry diagnostic to a bounded cross-launch
// buffer. Export Debug Logs prepends this buffer so the foregrounding session
// that produced a stale inset remains available even if Apollo is later killed.
// Never include post titles, account names, URLs, or other user content.
void ApolloAppendListLayoutDiag(NSString *line);

// iOS 26+ Liquid Glass: the tab bar's real expanded/collapsed state, read from
// the visual provider's stored `_currentMorphTarget` (0 expanded, 1 mid-morph,
// 2 minimized). UITabBar's own `_isMinimized` accessor is guarded by an
// Apple-app assertion (UIKit literally checks for Photos), so calling it from a
// sideloaded app crashes — the runtime ivar read is the only safe path.
// Returns NSNotFound with *known = NO when the private layout is missing
// (future iOS). Callers must treat unknown as "assume nothing" and fail OPEN
// (accept UIKit's writes), never as "expanded" — fighting UIKit per frame on a
// wrong guess is worse than missing one correction. Main-thread only.
NSInteger ApolloTabBarVisualMorphTarget(UITabBar *tabBar, BOOL *known);

// One-byte Swift Bool stored property on the tab bar's visual provider (e.g.
// "isAnimatingCollapsedState"). Swift ivars carry no useful ObjC type encoding
// (RuntimeBrowser shows `void`), so this mirrors UIKit's own one-byte
// read/write of the exported ivar offset. *known = NO when the ivar is gone.
// Main-thread only.
BOOL ApolloTabBarVisualProviderBoolIvar(UITabBar *tabBar, const char *name, BOOL *known);

// Dev-only login-persistence debug (see Tweak.xm): a report of where the account keychain item
// lives (each copy's access group / size / protection class), and a FLEX-gated action that
// poisons/restores the account item's protection class to reproduce the -25300 on demand. Both
// also write to the diag log.
NSString *ApolloDebugAccountKeychainReport(void);
NSString *ApolloDebugPoisonAccountAccessibility(void);

// Marks a tweak-created text node/label as our own UI chrome (AI summary pill,
// injected affordances, ...). Content pipelines that scan the view/node tree
// for USER content (e.g. translation's post-body candidate scan) must skip
// marked objects — otherwise tweak UI can be mistaken for the post body.
void ApolloMarkTweakUITextNode(id node);
BOOL ApolloTextNodeIsTweakUI(id node);
__END_DECLS
