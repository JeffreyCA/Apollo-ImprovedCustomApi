import AppIntents
import WidgetKit
import Foundation

/// Per-widget rotation offset, keyed by the widget's cache key (e.g.
/// "showerthoughts", "single.aww"). The interactive button bumps it; the
/// provider rotates that widget's cached posts so a new one shows first.
/// Lives in the extension's own UserDefaults — survives across refreshes.
enum Rotation {
    private static let defaults = UserDefaults.standard
    private static func key(_ k: String) -> String { "rw.offset.\(k)" }
    private static func stampKey(_ k: String) -> String { "rw.advanced.\(k)" }

    static func offset(_ k: String) -> Int { defaults.integer(forKey: key(k)) }
    static func advance(_ k: String) {
        defaults.set(offset(k) + 1, forKey: key(k))
        // Stamp the tap so the provider knows the reload that follows is a
        // "show another" request and serves the cached pool instantly instead
        // of refetching (see runPostTimeline).
        defaults.set(Date().timeIntervalSince1970, forKey: stampKey(k))
    }

    /// True if the ↻ button advanced this widget within the last couple of
    /// minutes — i.e. the timeline reload now running was caused by a tap.
    static func recentlyAdvanced(_ k: String) -> Bool {
        Date().timeIntervalSince1970 - defaults.double(forKey: stampKey(k)) < 120
    }

    /// Rotate `posts` so the current offset for `k` is first.
    static func rotated<T>(_ k: String, _ posts: [T]) -> [T] {
        guard posts.count > 1 else { return posts }
        let off = ((offset(k) % posts.count) + posts.count) % posts.count
        return Array(posts[off...] + posts[..<off])
    }
}

/// Interactive "show me another" button — confirmed to fire under Feather
/// (AppIntents perform() works at runtime even though AppIntents *config*
/// doesn't survive re-signing). The widget's cache key is passed in so the
/// right widget advances. Widget button intents must carry assigned parameter
/// values (no resolution).
struct NextItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Another Post"
    static var description = IntentDescription("Show the next post in this widget.")

    @Parameter(title: "Key") var key: String
    /// Widget kind to reload, so perform() can force the reload explicitly.
    @Parameter(title: "Kind") var kind: String?

    init() {}
    init(key: String, kind: String? = nil) { self.key = key; self.kind = kind }

    func perform() async throws -> some IntentResult {
        rwLog.log("NextItemIntent fired key=\(key, privacy: .public) kind=\(kind ?? "-", privacy: .public)")
        Rotation.advance(key)
        // Returning from a widget-button intent is *supposed* to reload that
        // widget's timeline automatically, but force it too — under third-party
        // re-signing the implicit reload is the one link we can't rely on.
        if let kind, !kind.isEmpty {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

/// Force a fresh fetch for one widget kind (used by Feed, which is a list and
/// doesn't rotate). The provider keeps its configured subreddit + sort; this
/// intent only asks WidgetKit to build a new timeline.
struct ReloadKindIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh"
    static var description = IntentDescription("Reload this widget.")

    @Parameter(title: "Kind") var kind: String

    init() {}
    init(kind: String) { self.kind = kind }

    func perform() async throws -> some IntentResult {
        rwLog.log("ReloadKindIntent fired kind=\(kind, privacy: .public)")
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        return .result()
    }
}
