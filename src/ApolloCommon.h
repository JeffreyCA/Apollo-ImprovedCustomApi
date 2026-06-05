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
BOOL IsLiquidGlass(void);
NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url);
BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL);
void ApolloFlushReadPostIDsToDefaults(void);
UIImage *ApolloEmojiSettingsIcon(NSString *emoji, UIColor *backgroundColor, CGFloat size);
UIImage *ApolloBuyMeACoffeeSettingsIcon(CGFloat size);
UIImage *ApolloRebornOptionsSettingsIcon(CGFloat size);

// Resolve a path to a bundled tweak resource across the install layouts we
// support (jailbreak rootful/rootless, Sideloadly/cyan/azule deb fuse, and
// inject-deb-local.sh). Returns nil if no layout has the file.
NSString *ApolloBundledResourcePath(NSString *baseName, NSString *extension);

// Returns the URL string a LinkButtonNode is presenting, by reading either
// the obj-c .url getter (older iOS) or the urlTextNode's attributed text
// (iOS 26+ where the Swift URL ivar is no longer ObjC-bridged). May return
// nil if neither path yields a usable string.
NSString *ApolloGetLinkButtonNodeURLString(id linkButtonNode);
void ApolloPresentWebURLFromViewController(UIViewController *presenter, NSURL *url);

// Returns YES for Apple's out-of-process share/compose controllers that the
// tweak must never traverse or mutate. Their class names end in
// "ComposeViewController" (e.g. MFMessageComposeViewController), so loose
// suffix matchers misidentify them as Apollo composers and crash when the
// GIF/composer machinery pokes at the remote view hierarchy (issue #366).
// Resolved via objc_getClass so we don't link MessageUI/Social.
BOOL ApolloIsSystemShareComposeController(UIViewController *controller);
__END_DECLS
