#import <UIKit/UIKit.h>

// A transient, self-dismissing toast rendered over the key window — the tweak's
// replacement for confirmation-only UIAlertControllers ("Copied", "Backup
// Complete", …) that made the user tap OK to acknowledge something they never
// needed to decide on. Reserve UIAlertController for real decisions (destructive
// confirmations, error recovery, text entry); use a toast for "it's done".
//
// Safe to call from any thread and before the UI is up (it hops to main and
// finds the key window itself). Showing a new toast replaces any visible one.

typedef NS_ENUM(NSInteger, ApolloToastStyle) {
    ApolloToastStyleInfo = 0,  // no glyph — a plain status line
    ApolloToastStyleSuccess,   // accent-tinted checkmark
    ApolloToastStyleError,     // red exclamation
};

__BEGIN_DECLS

// Convenience: a success toast (checkmark) with just a title.
void ApolloShowToast(NSString *message);

// Full form. `message` is required; `detail` is an optional second line (smaller,
// dimmer) for context. Pass a non-empty `symbolName` to override the style's
// default SF Symbol, or nil to use it.
void ApolloShowToastWithStyle(NSString *message, NSString *detail, ApolloToastStyle style, NSString *symbolName);

__END_DECLS
