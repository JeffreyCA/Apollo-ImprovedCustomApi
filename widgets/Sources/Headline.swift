import WidgetKit
import SwiftUI

// MARK: - Headline (Lock Screen only)

/// A Lock-Screen headline: the top post title from one chosen subreddit, rotating
/// through the current top posts. Text-only (accessory slots can't show images),
/// so it's cheap to build and safe for the tight accessory reload budget.
struct HeadlineProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = HeadlineConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.feed[0]]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.sample([WidgetSample.feed[0]])); return }
        let sub = resolvedSubreddit(configuration.subreddit, default: "worldnews")
        let post = PostCache.load("headline.\(sub)").first ?? WidgetSample.feed[0]
        completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: post, imageData: nil)])))
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "worldnews")
        let key = "headline.\(sub)"
        rwLog.log("getTimeline Headline r/\(sub, privacy: .public) family=\(familyName(context.family), privacy: .public)")
        runPostTimeline(
            code: configuration.setupCode, cacheKey: key,
            fetch: { try await $0.topPosts(subreddit: sub, sort: .hot, limit: 10) },
            assemble: { assembleText($0, key: key) },   // rotates through the top posts
            completion: completion)
    }
}

/// Lock-Screen rendering — reuses the shared accessory post view, labelled with
/// the post's subreddit. Tapping opens the post in Apollo.
struct HeadlineWidgetView: View {
    let entry: WidgetEntry
    var body: some View {
        let sub = firstPost(entry)?.subreddit ?? ""
        AccessoryPostView(entry: entry, label: sub.isEmpty ? "Reddit" : "r/\(sub)", icon: "newspaper")
    }
}
