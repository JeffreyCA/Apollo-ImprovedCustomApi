#import <UIKit/UIKit.h>
#import "settings/ApolloSettingsTableViewController.h"

// ApolloThemeManagerViewController — the v2 Theme Manager UI (spec §13).
//
// Two roles in one class:
//   * list mode (default init): consolidated Themes hub.
//   * editor mode (initEditorForThemeID:): name, variant, light/dark colours,
//     advanced overrides, live preview, apply.
//
// Subclasses ApolloSettingsTableViewController so that — exactly like the
// Apollo Reborn settings screen — it inherits the ambient Apollo theme
// (stock themes like Solarized/Outrun included) by sampling the presenting
// Appearance settings table, instead of rendering in the default grey/black.
@interface ApolloThemeManagerViewController : ApolloSettingsTableViewController

- (instancetype)initEditorForThemeID:(NSString *)themeID;

@end
