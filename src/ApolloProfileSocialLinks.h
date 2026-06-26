// ApolloProfileSocialLinks.h
//
// "Social Links in Profile" — surfaces the social links a redditor has set on
// their profile (Buy Me a Coffee, Instagram, X, YouTube, custom links, …) inside
// Apollo's profile header, in the gap between the username line and the bio.
//
//   • 1 link   → a long tappable pill: [icon] name   (tap opens the link)
//   • 2+ links → a row of circular brand badges       (tap anywhere → slide-up
//                "Social Links" sheet listing them all, each row tappable)
//
// Reddit's OAuth API (Apollo's token) can't read social links — about.json omits
// them and gql 404s our token — so, like Community Highlights / the Sidebar weekly
// stats, we scrape the server-rendered public profile page in a hidden WKWebView
// (it sails past Reddit's JS bot-challenge that plain requests get 403'd by).
// Results are cached per-username. Icons come from each link's domain favicon
// (bundled coffee glyph for Buy Me a Coffee / Ko-fi), so brands render without a
// bundled logo set. See ApolloProfileSocialLinks.m.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// A single social link parsed from a user's reddit profile.
@interface ApolloSocialLink : NSObject
@property(nonatomic, copy) NSString *title;        // display name, e.g. "icpryde"
@property(nonatomic, copy) NSString *urlString;    // absolute URL string
@property(nonatomic, copy) NSString *type;         // lowercased token: buymeacoffee, instagram, twitter, custom, …
@property(nonatomic, strong) NSURL *url;
@end

// In-header band, added as a subview of ApolloProfileHeaderView (ApolloUserAvatars.xm)
// and positioned by it between the username line and the bio. Self-manages its data
// via a cached hidden-WKWebView scrape of the public profile page.
@interface ApolloProfileSocialLinksView : UIView
// Assigning a (different) username (re)loads links from cache or kicks off a scrape.
@property(nonatomic, copy) NSString *username;
// Presenter used to open links and present the sheet.
@property(nonatomic, weak) UIViewController *hostViewController;
// Called on the main queue when the rendered height may have changed (links
// arrived, toggle flipped) so the host header can re-measure its tableHeaderView.
@property(nonatomic, copy) void (^heightChangedBlock)(void);
// 0 when the feature is off or there are no links; otherwise the band height.
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
// Pull-to-refresh: drop cached links for the current user and re-scrape.
- (void)refresh;
@end

// YES when the "Social Links in Profile" toggle is on (reads sSocialLinksInProfile).
FOUNDATION_EXPORT BOOL ApolloProfileSocialLinksEnabled(void);

// Posted by Settings when the toggle flips; the band observes it to reload.
FOUNDATION_EXPORT NSString *const ApolloSocialLinksToggleChangedNotification;
