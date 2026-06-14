import WidgetKit
import Foundation

/// One subreddit shortcut tile.
struct ShortcutItem: Hashable {
    let subreddit: String
    let iconData: Data?
    var colorHex: String? = nil
    var destinationURL: URL? = nil
    var iconSubreddit: String? = nil

    var label: String { subreddit }
    var iconLookupSubreddit: String { iconSubreddit ?? subreddit }
    var apolloURL: URL? { destinationURL ?? RedditPost.subredditURL(subreddit) }
}

struct ShortcutsEntry: TimelineEntry {
    let date: Date
    let items: [ShortcutItem]
    let needsConfig: Bool

    static let placeholder = ShortcutsEntry(
        date: Date(),
        items: ["apple", "ios", "apolloapp", "showerthoughts", "aww", "EarthPorn", "todayilearned", "popular"]
            .map { ShortcutItem(subreddit: $0, iconData: nil) },
        needsConfig: false)
}

/// Subreddit shortcuts: a configurable grid of tappable subreddits that open in
/// Apollo. No network is required (tiles fall back to letter avatars); if the
/// shared setup code is present, real subreddit icons are fetched.
struct ShortcutsProvider: IntentTimelineProvider {
    typealias Entry = ShortcutsEntry
    typealias Intent = ShortcutsConfigurationIntent

    func placeholder(in context: Context) -> ShortcutsEntry { .placeholder }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (ShortcutsEntry) -> Void) {
        let items = Self.items(for: configuration)
        if items.isEmpty { completion(.placeholder); return }
        completion(ShortcutsEntry(date: Date(),
                                  items: items,
                                  needsConfig: false))
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<ShortcutsEntry>) -> Void) {
        let shortcuts = Self.items(for: configuration)
        guard !shortcuts.isEmpty else {
            completion(Timeline(entries: [ShortcutsEntry(date: Date(), items: [], needsConfig: true)],
                                policy: .never))
            return
        }

        Task {
            var items = shortcuts
            // Best-effort icons via the shared setup code; letter avatars otherwise.
            if let creds = SetupCode.resolve(configuration.setupCode) {
                let client = RedditAppOnlyClient(clientID: creds.clientID, userAgent: creds.resolvedUserAgent)
                items = await Self.withIcons(shortcuts, client: client)
            }
            // Refresh icons daily; subreddit icons rarely change.
            completion(Timeline(entries: [ShortcutsEntry(date: Date(), items: items, needsConfig: false)],
                                policy: .after(Date().addingTimeInterval(24 * 60 * 60))))
        }
    }

    /// Concurrently fetch each subreddit's icon + brand color, preserving order.
    private static func withIcons(_ items: [ShortcutItem], client: RedditAppOnlyClient) async -> [ShortcutItem] {
        await withTaskGroup(of: (Int, Data?, String?).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    let about = try? await client.subredditAbout(item.iconLookupSubreddit)
                    let data = await ImageLoader.fetchDownsampled(about?.icon ?? nil, maxPixel: 120)
                    return (i, data, about?.colorHex)
                }
            }
            var icons: [Int: Data?] = [:]
            var colors: [Int: String?] = [:]
            for await (i, data, color) in group { icons[i] = data; colors[i] = color }
            return items.enumerated().map { idx, item in
                ShortcutItem(subreddit: item.subreddit,
                             iconData: icons[idx] ?? item.iconData,
                             colorHex: colors[idx] ?? item.colorHex,
                             destinationURL: item.destinationURL,
                             iconSubreddit: item.iconSubreddit)
            }
        }
    }

    static func items(for configuration: Intent) -> [ShortcutItem] {
        switch configuration.source {
        case .popular:
            return [
                preset("Popular", url: "apollo://reddit.com/r/popular", icon: "popular"),
                preset("All", url: "apollo://reddit.com/r/all", icon: "all"),
                custom("AskReddit"), custom("todayilearned"), custom("technology"), custom("pics"),
                custom("aww"), custom("news"),
            ]
        case .new:
            return [
                preset("Popular New", url: "apollo://reddit.com/r/popular/new", icon: "popular"),
                preset("All New", url: "apollo://reddit.com/r/all/new", icon: "all"),
                custom("worldnews"), custom("technology"), custom("apple"), custom("iOS"),
                custom("movies"), custom("gaming"),
            ]
        case .home:
            return [
                preset("Home", url: "apollo://reddit.com", icon: "popular"),
                preset("Popular", url: "apollo://reddit.com/r/popular", icon: "popular"),
                preset("All", url: "apollo://reddit.com/r/all", icon: "all"),
                custom("AskReddit"), custom("todayilearned"), custom("technology"),
                custom("pics"), custom("aww"),
            ]
        case .custom:
            return parseSubs(configuration.subreddits).map { custom($0) }
        @unknown default:
            let customItems = parseSubs(configuration.subreddits).map { custom($0) }
            return customItems.isEmpty ? [] : customItems
        }
    }

    private static func custom(_ sub: String) -> ShortcutItem {
        ShortcutItem(subreddit: sub, iconData: nil)
    }

    private static func preset(_ label: String, url: String, icon: String) -> ShortcutItem {
        ShortcutItem(subreddit: label,
                     iconData: nil,
                     destinationURL: URL(string: url),
                     iconSubreddit: icon)
    }

    /// Split a user-typed list on commas/whitespace/newlines, normalize, dedupe,
    /// cap at 8 (the large family's capacity).
    static func parseSubs(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let parts = raw.split(whereSeparator: { ", \n\t".contains($0) })
        var seen = Set<String>()
        var out: [String] = []
        for p in parts {
            let s = RedditPost.normalizeSubreddit(String(p))
            guard !s.isEmpty else { continue }
            let lower = s.lowercased()
            if seen.insert(lower).inserted { out.append(s) }
            if out.count == 8 { break }
        }
        return out
    }
}
