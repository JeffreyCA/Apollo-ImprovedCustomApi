// ApolloBadgeBookScraper.{h,m}
//
// Resolves, per redditor, WHICH catalogue collectibles they actually have:
//   • Trophy Case — the trophies shown on their profile page
//   • Achievements — which of the catalogue badges they've earned
//
// FAST PATH (default): both pages are plain server-rendered HTML, so two direct
// NSURLSession GETs — fired in PARALLEL, with the active account's web-session
// cookies attached when available — fetch and natively parse everything in
// well under a second. No WKWebView, no JS, no polling:
//   1. /user/<name>/                → <shreddit-profile-trophy-list> markup
//   2. /user/<name>/achievements/   → <achievement-badge id unlocked-at url> tags
// (Plus a parallel try of the official trophies API, currently dead server-side
// for third-party bearers — kept in case Reddit revives it.)
//
// FALLBACK: when a direct GET doesn't get a real Reddit page back (flagged
// network serving the "log in to continue" block to logged-out requests), the
// old hidden in-memory WKWebView flow covers the missing phases.
//
// Results are cached per-username for the session so re-visiting a profile is free.

#import <Foundation/Foundation.h>
#import "ApolloBadgeBookCatalog.h"

NS_ASSUME_NONNULL_BEGIN

@interface ApolloUserBadges : NSObject
@property(nonatomic, copy) NSString *username;
// Catalogue achievement identifiers the user has earned.
@property(nonatomic, strong) NSSet<NSString *> *earnedAchievementIDs;
// The user's actual trophies, as ApolloBadgeItems (catalogue-joined where possible;
// live/uncatalogued ones carry their scraped title/bio/imageURL with isLiveUncatalogued=YES).
@property(nonatomic, strong) NSArray<ApolloBadgeItem *> *trophies;
// Earned achievement id → the art URL the achievements page served for it. For
// badges whose catalogue entry has no bundled icon (Reddit publicly serves only
// a faint "ghost" placeholder until someone earns them), this is the only source
// of the real artwork — the UI async-loads from here when bundledImage is nil.
@property(nonatomic, strong) NSDictionary<NSString *, NSString *> *earnedAchievementImageURLs;
// NO when the achievements page couldn't be read (e.g. login-gated / markup miss),
// so the UI can present the book without asserting a (wrong) all-locked state.
@property(nonatomic) BOOL achievementsResolved;
// NO when the profile/trophy page never rendered (load failure) — distinct from
// "rendered, but the user simply has no trophies".
@property(nonatomic) BOOL trophiesResolved;

- (NSUInteger)earnedAchievementCount;
@end

// completion(result) on the main queue — synchronous on a warm cache, else after the
// scrape. result is non-nil once at least the profile page resolved; nil only on hard
// failure (not cached, so a later visit retries).
FOUNDATION_EXPORT void ApolloBadgeBookFetch(NSString *username, void (^completion)(ApolloUserBadges *_Nullable result));

// Posted on the main queue (object = the username string) when an already-delivered
// ApolloUserBadges gains late data — the trophy API delivers instantly, and the
// achievements scrape merges into the same cached instance when it lands. Live UIs
// (strip, book screen) observe this to refresh.
FOUNDATION_EXPORT NSString *const ApolloBadgeBookUserUpdatedNotification;

// Drop any cached result for a username, memory AND the TTL disk cache
// (pull-to-refresh). Pass nil to clear all.
FOUNDATION_EXPORT void ApolloBadgeBookInvalidate(NSString *_Nullable username);

#if APOLLO_SIM_BUILD
// Sim-only test hook: plant a result in the cache so UI states (silhouettes,
// earned counts) can be exercised without a live scrape.
FOUNDATION_EXPORT void ApolloBadgeBookDebugSeedResult(ApolloUserBadges *result);
#endif

NS_ASSUME_NONNULL_END
