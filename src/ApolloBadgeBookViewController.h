// ApolloBadgeBookViewController.{h,m}
//
// The full "Badge Book" screen: a segmented view of a redditor's collectibles.
//   • Achievements — the full catalogue grouped by category; earned in colour,
//     locked dimmed. Renders instantly from bundled icons; the earned/locked
//     state fills in when the per-user scrape resolves.
//   • Trophy Case  — the user's actual trophies.
//
// Pushed onto the profile's navigation stack from the header badge strip, for
// both the signed-in user and anyone else's profile.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloBadgeBookViewController : UIViewController
- (instancetype)initWithUsername:(NSString *)username;
@property(nonatomic, copy, readonly) NSString *username;
@end

// Push (or, if there's no nav controller, present) the Badge Book for a username.
FOUNDATION_EXPORT void ApolloBadgeBookPresentForUsername(NSString *username, UIViewController *from);

NS_ASSUME_NONNULL_END
