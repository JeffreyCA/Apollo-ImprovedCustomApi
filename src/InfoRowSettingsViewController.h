#import "ApolloSettingsTableViewController.h"

/// "Info Row" sub-screen (pushed from the Apollo Reborn settings root). Hosts
/// the press-and-hold magnifier toggle plus a per-icon switch for each info-row
/// action — Upvote, Comments, Timestamp, and Translation — letting the user
/// pick which icons respond to a tap (and which the magnifier offers). The
/// Translation switch is smart-gated: it fades out until a translation language
/// marker can appear (Tap to Translate or a Details toggle enabled in
/// Translation settings), and when on it overrides those.
@interface InfoRowSettingsViewController : ApolloSettingsTableViewController
@end
