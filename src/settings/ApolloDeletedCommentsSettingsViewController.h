#import "ApolloSettingsForm.h"

// "Deleted Comments" sub-screen pushed from the tweak settings' General
// section: Always Show Deleted Comments, Tap to Show Deleted Comments, and
// Passive Deleted Comments (per-thread enable from the comments "..." menu).
// Always Show and Passive are mutually exclusive; turning one on turns the
// other off. Declarative form — see -buildForm.
@interface ApolloDeletedCommentsSettingsViewController : ApolloSettingsFormViewController
@end
