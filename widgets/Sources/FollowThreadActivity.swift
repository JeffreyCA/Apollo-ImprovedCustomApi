import ActivityKit
import Foundation

/// Re-declaration of Apollo's own `FollowThreadActivityAttributes`, so the
/// Apollo-Reborn widget extension can render the "follow thread" Live Activity.
///
/// ## Why this lives here
/// Apollo's main binary still *starts* the activity (`LiveActivityHelper` calls
/// `Activity<FollowThreadActivityAttributes>.request(...)`) and mints the APNs
/// push token, but the activity's **UI** (`FollowThreadLiveActivity`, an
/// `ActivityConfiguration`) shipped only inside the stock
/// `AthenaWidgetExtension.appex`. Reborn removes that extension (it crash-loops
/// without API keys and poisons WidgetKit enumeration), which also dropped the
/// Live Activity renderer — so pushed updates were accepted by APNs (HTTP 200)
/// but had nothing on-device to draw them. Declaring the configuration in
/// `ApolloRebornWidgets.appex` restores it.
///
/// ## Why a separate-module re-declaration works
/// ActivityKit routes a running activity to the `ActivityConfiguration` whose
/// attributes type has the same **unqualified** name (`FollowThreadActivity\
/// Attributes`); the module differs (`Apollo` vs `ApolloRebornWidgets`). This
/// is the standard "shared attributes" pattern and is exactly how the stock
/// `AthenaWidgetExtension` — itself a separate module — rendered this same
/// activity. The attributes are passed app→widget via `Codable`, so the stored
/// property names must match Apollo's struct verbatim.
///
/// ## Why the `ContentState` keys are load-bearing
/// Pushed updates arrive as the APNs `content-state` JSON and are decoded into
/// `ContentState` by key (Swift synthesizes `CodingKeys` from the property
/// names). These names must match BOTH Apollo's struct AND the apollo-backend
/// `DynamicIslandNotification` JSON tags
/// (`internal/worker/live_activities.go`) — `postTotalComments`, `postScore`,
/// `commentId`, `commentAuthor`, `commentBody`, `commentAge`, `commentScore`.
/// A mismatch makes ActivityKit silently drop every update.
struct FollowThreadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Total comments on the post (always sent).
        var postTotalComments: Int
        /// Post score / upvotes (always sent).
        var postScore: Int
        /// The most recent surfaced comment (all optional — absent until the
        /// backend finds a fresh top-level comment).
        var commentAuthor: String?
        var commentScore: Int?
        /// Comment creation time as a Unix timestamp in **seconds**
        /// (`comment.CreatedAt.Unix()` on the backend), not a duration.
        var commentAge: Double?
        var commentBody: String?
        var commentId: String?
    }

    /// Static, set once when the activity starts; never changes via push.
    let postID: String
    let postTitle: String
    let postAuthor: String
    let subreddit: String
}
