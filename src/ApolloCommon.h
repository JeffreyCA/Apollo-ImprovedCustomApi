#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

// On iOS 26, NSLog redacts strings, so use os_log: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes#NSLog
// Uses a dedicated subsystem so OSLogStore can efficiently filter our entries.
#define ApolloLog(fmt, ...) do { \
    NSString *logMessage = [NSString stringWithFormat:@"[ApolloFix] " fmt, ##__VA_ARGS__]; \
    os_log_with_type(ApolloFixLog(), OS_LOG_TYPE_DEFAULT, "%{public}s", [logMessage UTF8String]); \
} while(0)

__BEGIN_DECLS
os_log_t ApolloFixLog(void);
NSString *ApolloCollectLogs(void);
NSString *ApolloCollectAILogs(void);
BOOL IsLiquidGlass(void);
NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url);
BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL);
void ApolloFlushReadPostIDsToDefaults(void);
UITableView *ApolloInheritedSettingsThemeSourceTableView(UITableViewController *controller);
void ApolloApplyInheritedSettingsTableTheme(UITableViewController *controller);
UIImage *ApolloEmojiSettingsIcon(NSString *emoji, UIColor *backgroundColor, CGFloat size);
UIImage *ApolloBuyMeACoffeeSettingsIcon(CGFloat size);
UIImage *ApolloRebornOptionsSettingsIcon(CGFloat size);

// Resolve a path to a bundled tweak resource across the install layouts we
// support (jailbreak rootful/rootless, Sideloadly/cyan/azule deb fuse, and
// inject-deb-local.sh). Returns nil if no layout has the file.
NSString *ApolloBundledResourcePath(NSString *baseName, NSString *extension);

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

// Issue #515 (ApolloPublicStickyAsSubreddit): when `menuTitle` is the removal
// "Notify user via…" menu, append a "Public Sticky from Subreddit" UIAction to
// `children` (an NSMutableArray<UIMenuElement *>). No-op for any other menu.
// Called from ApolloNativeActionMenuBuildMenu as it converts the action sheet.
void ApolloInjectPublicStickyAsSubredditIfNeeded(NSMutableArray *children, NSString *menuTitle);

// ApolloDeletedCommentsMenu: when the comments view's "..." menu is being
// built, append a "Show/Hide Deleted Comments" UIAction to `children`
// (an NSMutableArray<UIMenuElement *>). No-op for any other menu. Called from
// ApolloNativeActionMenuBuildMenu as it converts the action sheet; the
// ActionController is tagged on first build so re-builds re-inject and other
// menus can't claim the item.
void ApolloInjectDeletedCommentsMenuItemIfNeeded(NSMutableArray *children, NSString *menuTitle, id actionController);

// Container keychain mirror (Tweak.xm): the Valet items the real keychain could not persist
// on a keychain-broken sideload, so a backup taken there still carries the signed-in account.
// Returns an array of { "service", "account", "data" } dicts (empty when the mirror is dormant).
NSArray<NSDictionary *> *ApolloKeychainMirrorItemsForBackup(void);

// Append a login-persistence diagnostic line to the cross-launch buffer in the app container.
// Mirrors the line into a file that survives force-quit, so Export Debug Logs carries the
// session that actually signed the user out. Safe to call from any thread; never logs secrets.
void ApolloAppendLoginDiag(NSString *line);

// Dev-only login-persistence debug (see Tweak.xm): a report of where the account keychain item
// lives (each copy's access group / size / protection class), and a FLEX-gated action that
// poisons/restores the account item's protection class to reproduce the -25300 on demand. Both
// also write to the diag log.
NSString *ApolloDebugAccountKeychainReport(void);
NSString *ApolloDebugPoisonAccountAccessibility(void);
__END_DECLS
