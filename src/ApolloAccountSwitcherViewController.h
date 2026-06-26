#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Apollo-Reborn's own account switcher: lists every signed-in account with a
// per-account API-key status badge, and lets the user edit/clear each
// account's Reddit OAuth credentials (see ApolloAccountCredentials.{h,m}).
//
// Visually this fully replaces Apollo's native AccountManagerViewController,
// but every actual switch/add/delete is performed by driving a real, live
// instance of that native class through its existing ObjC-visible selectors
// (verified via Hopper decompilation of -[AccountManagerViewController
// tableView:didSelectRowAtIndexPath:] / -addBarButtonItemTapped: /
// -tableView:commitEditingStyle:forRowAtIndexPath:) — so account persistence,
// keychain writes, and OAuth add-account flows are still 100% Apollo's own
// code, not a reimplementation.
@interface ApolloAccountSwitcherViewController : UITableViewController

// Whether the custom switcher should be presented in place of Apollo's
// native AccountManagerViewController. Backed by UDKeyUseCustomAccountSwitcher
// (default YES) — flip to NO via defaults as an emergency fallback to the
// stock switcher if a future Apollo build changes the native ObjC selector
// surface this file drives (see ApolloAccountSwitcherViewController.xm).
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
