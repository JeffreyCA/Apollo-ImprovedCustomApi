// ApolloBadgeBookStrip.{h,m}
//
// The compact "Badge Book" band shown in a redditor's profile header (between the
// bio and the tab content). It previews a few of the user's earned achievements
// and trophies as small icons and, tapped anywhere, opens the full
// ApolloBadgeBookViewController.
//
// API mirrors ApolloProfileSocialLinksView so ApolloUserAvatars' header hosts it
// with the same wiring (username in, height out, host VC for presentation).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloBadgeBookStripView : UIView
// Assigning a (different) username loads the user's badges (cached) and refreshes.
@property(nonatomic, copy, nullable) NSString *username;
// Presenter used to push/present the full Badge Book.
@property(nonatomic, weak) UIViewController *hostViewController;
// Called on the main queue when the rendered height may have changed, so the host
// header can re-measure its tableHeaderView.
@property(nonatomic, copy, nullable) void (^heightChangedBlock)(void);
// 0 when the feature is off; otherwise the band height.
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
// Pull-to-refresh: drop cached badges for the current user and re-scrape.
- (void)refresh;
// Permanently use bundled trophies for this settings preview; an empty array shows none.
- (void)apollo_useSettingsPreviewTrophyTitles:(NSArray<NSString *> *)titles;
@end

// YES when the Badge Book feature is enabled (reads the cached sBadgeBookEnabled).
FOUNDATION_EXPORT BOOL ApolloBadgeBookEnabled(void);

// Posted by Settings when the toggle flips; the band observes it to reload.
FOUNDATION_EXPORT NSString *const ApolloBadgeBookToggleChangedNotification;

NS_ASSUME_NONNULL_END
