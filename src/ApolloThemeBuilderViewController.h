#import "ApolloSettingsTableViewController.h"

// Settings page for the custom theme (see ApolloThemeBuilder.h for the
// engine). Pushed from Apollo's Settings list next to the other tweak pages.
// Subclasses ApolloSettingsTableViewController so that — when the custom theme
// being built is NOT the active app theme — the page inherits Apollo's main app
// theme colour scheme like every other tweak settings page, instead of falling
// back to the generic system grouped colours. When the custom theme IS active,
// the page keeps painting itself with the live role colours (see applyThemeColors
// / willDisplayCell) so edits preview in place.
@interface ApolloThemeBuilderViewController : ApolloSettingsTableViewController
@end
