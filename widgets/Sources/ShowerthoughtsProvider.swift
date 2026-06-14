import WidgetKit
import Foundation

/// Showerthoughts: top of r/showerthoughts, text only, rotating.
/// Classic SiriKit IntentTimelineProvider (AppIntents doesn't survive re-sign).
struct ShowerthoughtsProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = ShowerthoughtsConfigurationIntent

    func placeholder(in context: Context) -> WidgetEntry { .sample([WidgetSample.showerthought]) }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.sample([WidgetSample.showerthought])); return }
        let cached = PostCache.load("showerthoughts")
        if let first = cached.first {
            completion(WidgetEntry(date: Date(), state: .posts([RenderPost(post: first, imageData: nil)])))
        } else {
            completion(.sample([WidgetSample.showerthought]))
        }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        rwLog.log("getTimeline Showerthoughts family=\(familyName(context.family), privacy: .public)")
        runPostTimeline(
            code: configuration.setupCode,
            cacheKey: "showerthoughts",
            fetch: { try await $0.topPosts(subreddit: "showerthoughts", sort: .topWeek) },
            // Rotate by the button-driven offset so each "next" tap shows a new one.
            assemble: { assembleText($0, key: "showerthoughts") },
            completion: completion)
    }
}
