#import <UIKit/UIKit.h>

// Settings search: a UISearchController on Apollo's native Settings root that
// indexes every settings row — the tweak's own screens (scanned live from the
// route registry, so the index always matches current row visibility) and
// Apollo's native screens (a generated snapshot table; see
// ApolloSettingsSearchNativeIndex.h). Selecting a result replays real
// navigation by label matching: tap the same rows a user would, then scroll to
// and flash the target row. No stored index paths, so results fail soft (land
// on the closest screen) when a row moves.

__BEGIN_DECLS

// Attach the search controller to the native Settings root VC's navigation
// item. Idempotent per VC. Called from the SettingsViewController hook.
void ApolloSettingsSearchAttach(UIViewController *settingsVC);

// Hand the attached search bar over to the system's scroll-away behavior. The
// bar is attached pinned so it's visible the moment Settings opens; this is
// called from the first -viewDidAppear: (once per VC) so it then collapses and
// reveals with the list the way a stock iOS search bar does.
void ApolloSettingsSearchEnableScrollAway(UIViewController *settingsVC);

__END_DECLS
