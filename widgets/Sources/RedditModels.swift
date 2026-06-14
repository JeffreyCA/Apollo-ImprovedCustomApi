import Foundation

/// One Reddit post, trimmed to what the widgets render. Shared by every widget.
struct RedditPost: Codable, Hashable {
    var id: String
    var title: String
    var author: String
    var subreddit: String
    var score: Int
    var numComments: Int
    var permalink: String          // "/r/sub/comments/id/slug/"
    var selftext: String           // body text (Jokes punchline, etc.)
    var thumbnailURL: String?      // small thumbnail for feed rows
    var imageURL: String?          // larger preview for Photo / Single Post
    var isImagePost: Bool
    var created: Double?           // created_utc epoch seconds (optional: old caches lack it)

    /// Short relative age ("3h", "2d") for the Detailed display mode. Nil when
    /// the timestamp is unavailable (e.g. decoded from an older cache).
    var ageString: String? {
        guard let created else { return nil }
        let secs = Date().timeIntervalSince1970 - created
        guard secs >= 0 else { return nil }
        if secs < 3600 { return "\(max(1, Int(secs / 60)))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }

    /// Deep link that opens this post natively in Apollo. Apollo rewrites a
    /// reddit.com URL to the apollo:// scheme; we emit that scheme directly so
    /// tapping routes straight into the app (see ApolloCommon.m
    /// ApolloURLByConvertingResolvedURLToApolloScheme).
    var apolloURL: URL? {
        let path = permalink.hasPrefix("/") ? permalink : "/" + permalink
        return URL(string: "apollo://reddit.com\(path)")
    }

    static func subredditURL(_ sub: String) -> URL? {
        let clean = RedditPost.normalizeSubreddit(sub)
        return URL(string: "apollo://reddit.com/r/\(clean)")
    }

    /// Strip "r/", "/r/", leading/trailing slashes and whitespace from a
    /// user-typed subreddit so "r/EarthPorn", "/r/earthporn/", "earthporn" all
    /// normalize the same.
    static func normalizeSubreddit(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/r/", "r/", "/"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        // Keep only characters Reddit allows in a subreddit/multireddit name
        // (letters, digits, underscore, and "+" for multis). This is what makes
        // the URLs we build safe — a stray "?", "#", space, etc. from a typed
        // widget config could otherwise produce a nil URL and crash the
        // extension, which poisons WidgetKit's enumeration of every widget.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+")
        return String(s.unicodeScalars.filter { allowed.contains($0) })
    }
}

/// How much metadata the Post widget renders (PRD §8.6).
///   clean    – title + subreddit only
///   standard – + score + comments
///   detailed – + age + author
enum DisplayMode: Int, Codable, Hashable {
    case clean, standard, detailed
}

/// How much caption a content widget overlays on its post (shared by Post and
/// Photo so both have an identical "Caption" picker).
///   hidden   – no overlay text (clean image)
///   title    – title only
///   standard – title + score + comments
///   detailed – + age/author (and the body preview, for text posts)
/// `DisplayMode` (above) is the internal density the stats line renders.
enum Caption: Int, Codable, Hashable {
    case hidden, title, standard, detailed

    var showsTitle: Bool { self != .hidden }
    var showsStats: Bool { self == .standard || self == .detailed }
    var showsPreview: Bool { self == .detailed }
    var density: DisplayMode { self == .detailed ? .detailed : .standard }
}

/// Date-overlay style for the Calendar widget — each is a distinct typographic
/// treatment (a different SF system font design). Raw values ride along in a
/// `WidgetEntry`; the SiriKit `RebornDateStyle` maps onto these in `CalendarProvider`.
///   rounded   – SF Pro Rounded, friendly, big day number
///   serif     – New York serif, editorial / masthead
///   mono      – monospaced, digital date readout
///   condensed – condensed-width heavy, sports-poster
///   stamp     – outlined, rotated date-stamp
enum CalendarStyle: Int, Codable, Hashable {
    case rounded, serif, mono, condensed, stamp
}

/// Listing sort, mapped to the Reddit API path + time window.
enum WidgetSort {
    case hot, new, top, topWeek

    var path: String {
        switch self {
        case .hot: return "hot"
        case .new: return "new"
        case .top, .topWeek: return "top"
        }
    }
    /// `t` window (only meaningful for the `top` sorts).
    var timeWindow: String? {
        switch self {
        case .top: return "day"
        case .topWeek: return "week"
        default: return nil
        }
    }
}
