import Foundation

/// Where a content widget (Feed, Post, Photo, Headline, Calendar) reads its
/// posts from. One free-text field ("Subreddit or Multireddit") accepts every
/// form people actually paste, so the widget config stays a single box:
///
///   soccer · r/soccer · https://reddit.com/r/soccer          → one subreddit
///   soccer+nba · soccer, nba · r/soccer r/nba                → several (Reddit's a+b listing)
///   home · popular · all                                     → the built-in feeds
///   https://reddit.com/user/foo/m/bar · u/foo/m/bar          → someone's multireddit
///   m/bar · /me/m/bar · bar (when bar is one of yours)       → your own multireddit
///
/// Home and your own multireddits are read with the signed-in account — they
/// need the setup code copied *with account* (Apollo → Settings → Apollo
/// Reborn). Everything else is public and goes through the app-only token,
/// exactly as before.
enum FeedSource: Hashable {
    case home
    case popular
    case all
    case subreddits([String])
    /// `owner == nil` means "the signed-in user's" (`/me/m/<name>`).
    case multireddit(owner: String?, name: String)

    /// Sources only a user token can read.
    var needsAccount: Bool {
        switch self {
        case .home: return true
        case .multireddit(let owner, _): return owner == nil
        default: return false
        }
    }

    var isMultireddit: Bool {
        if case .multireddit = self { return true }
        return false
    }

    /// oauth.reddit.com path the sort segment is appended to ("" for home, so
    /// Home + Hot is `https://oauth.reddit.com/hot`).
    var listingPath: String {
        switch self {
        case .home: return ""
        case .popular: return "/r/popular"
        case .all: return "/r/all"
        case .subreddits(let subs): return "/r/" + subs.joined(separator: "+")
        case .multireddit(let owner, let name):
            if let owner { return "/user/\(owner)/m/\(name)" }
            return "/me/m/\(name)"
        }
    }

    /// Header label: "Home", "Popular", "All", "r/soccer", "r/soccer+nba",
    /// "m/bar". Long subreddit lists collapse to "r/first +N" so the Feed
    /// header keeps room for its ↻ button.
    var label: String {
        switch self {
        case .home: return "Home"
        case .popular: return "Popular"
        case .all: return "All"
        case .subreddits(let subs):
            let joined = "r/" + subs.joined(separator: "+")
            if subs.count <= 1 || joined.count <= 22 { return joined }
            return "r/\(subs[0]) +\(subs.count - 1)"
        case .multireddit(_, let name): return "m/\(name)"
        }
    }

    /// Stable id for cache keys. A plain subreddit keeps its bare name so the
    /// caches of already-configured widgets carry over unchanged.
    var cacheKey: String {
        switch self {
        case .home: return "home"
        case .popular: return "popular"
        case .all: return "all"
        case .subreddits(let subs): return subs.joined(separator: "+")
        case .multireddit(let owner, let name): return "m:\(owner ?? "me")/\(name)"
        }
    }

    /// Deep link that opens this feed in Apollo. `username` resolves "my"
    /// multireddits (Apollo's router only knows `/user/<name>/m/<multi>`);
    /// without it there's no link rather than a broken one.
    func apolloURL(username: String?) -> URL? {
        switch self {
        case .home: return URL(string: "apollo://reborn/home")
        case .popular: return URL(string: "apollo://reddit.com/r/popular")
        case .all: return URL(string: "apollo://reddit.com/r/all")
        case .subreddits(let subs): return URL(string: "apollo://reddit.com/r/\(subs.joined(separator: "+"))")
        case .multireddit(let owner, let name):
            guard let who = owner ?? username, !who.isEmpty else { return nil }
            return URL(string: "apollo://reddit.com/user/\(who)/m/\(name)")
        }
    }

    // MARK: Parsing

    /// Names Reddit allows in a subreddit / multireddit / username path segment.
    /// Everything else is dropped, which is what keeps every URL we build
    /// non-nil (a nil URL force-unwrapped in an extension poisons WidgetKit's
    /// enumeration of ALL the app's widgets).
    private static let nameChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func cleanName(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { nameChars.contains($0) })
    }

    private static let homeWords: Set<String> = ["home", "frontpage", "front page", "front-page", "best"]
    private static let sortWords: Set<String> = ["hot", "new", "top", "best", "rising", "controversial", "gilded"]
    /// List separators for several subreddits, matched per unicode scalar:
    /// "\r\n" is ONE Character, so a Character-level check would miss both a
    /// lone "\n" (when written next to "\r" in a literal) and a CRLF pair.
    private static let listSeparators = CharacterSet(charactersIn: "+,; \t\r\n")
    private static let pathMarkers: Set<String> = ["r", "u", "user", "m", "me"]

    /// Parse the free-text field. `ownMultis` is the (lowercased) set of the
    /// signed-in user's multireddit names, from `OwnMultis`; a bare name that
    /// matches one of them resolves to that multireddit, while an explicit
    /// "r/name" always forces the subreddit.
    static func parse(_ raw: String?, default def: FeedSource, ownMultis: Set<String> = []) -> FeedSource {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return def }

        // Drop a query string / fragment, the URL scheme, and a reddit.com host
        // (www./old./new./np. …) so a pasted link is just its path.
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        for scheme in ["https://", "http://", "apollo://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
            break
        }
        if let host = s.lowercased().range(of: "reddit.com"), !s[..<host.lowerBound].contains("/") {
            s = String(s[host.upperBound...])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n"))
        let lower = s.lowercased()
        // A bare reddit.com link, or the words people use for the front page.
        if lower.isEmpty || homeWords.contains(lower) { return .home }

        // Path segments, minus a trailing sort ("r/soccer/top", "user/a/m/b/new")
        // — but "r/hot" is the subreddit named hot, so a two-segment path only
        // loses its tail when the head isn't a path marker.
        var parts = s.split(separator: "/").map(String.init)
        if parts.count >= 2, let last = parts.last, sortWords.contains(last.lowercased()),
           parts.count >= 3 || !pathMarkers.contains(parts[0].lowercased()) {
            parts.removeLast()
        }
        let lowerParts = parts.map { $0.lowercased() }

        // Multireddit forms: user/<owner>/m/<name>, u/<owner>/m/<name>,
        // <owner>/m/<name>, me/m/<name>, m/<name>.
        if let mi = lowerParts.firstIndex(of: "m") {
            guard mi + 1 < parts.count else { return def }
            let name = cleanName(parts[mi + 1])
            guard !name.isEmpty else { return def }
            let before = Array(lowerParts[..<mi])
            if before.isEmpty || before == ["me"] || before == ["user", "me"] || before == ["u", "me"] {
                return .multireddit(owner: nil, name: name)
            }
            if before.count == 2, before[0] == "user" || before[0] == "u" {
                let owner = cleanName(parts[mi - 1])
                return owner.isEmpty ? def : .multireddit(owner: owner, name: name)
            }
            if before.count == 1 {
                let owner = cleanName(parts[mi - 1])
                return owner.isEmpty ? def : .multireddit(owner: owner, name: name)
            }
            return def
        }

        // Subreddit forms. "r/" is a marker, not a name, and forces the
        // subreddit reading of a bare name that also matches one of the
        // user's multireddits.
        let forcedSubreddit = lowerParts.first == "r"
        var names: [String] = []
        var seen = Set<String>()
        for token in parts.joined(separator: "+").split(whereSeparator: { $0.unicodeScalars.allSatisfy(listSeparators.contains) }) {
            let t = String(token)
            if t.lowercased() == "r" { continue }           // "r/a r/b" → r, a, r, b
            let n = cleanName(t)
            guard !n.isEmpty else { continue }
            if seen.insert(n.lowercased()).inserted { names.append(n) }
        }
        guard !names.isEmpty else { return def }

        if names.count == 1 {
            let n = names[0].lowercased()
            if n == "popular" { return .popular }
            if n == "all" { return .all }
            if homeWords.contains(n) { return .home }
            if !forcedSubreddit, ownMultis.contains(n) { return .multireddit(owner: nil, name: names[0]) }
        }
        return .subreddits(names)
    }
}

/// Cache of the signed-in user's multireddit names (and their username, learned
/// from the multireddit paths), so a bare "nintendo" in a widget can resolve to
/// m/nintendo when it's one of theirs. Keyed by the account (a hash of client
/// id + refresh token), refreshed at most every few hours by `RedditClient`.
enum OwnMultis {
    private static let defaults = UserDefaults.standard
    private static let maxAge: TimeInterval = 6 * 3600

    private static func namesKey(_ account: String) -> String { "rw.multis.\(account)" }
    private static func stampKey(_ account: String) -> String { "rw.multisAt.\(account)" }
    private static func ownerKey(_ account: String) -> String { "rw.multisOwner.\(account)" }

    /// Lowercased multireddit names for `account` (empty when unknown).
    static func names(for account: String?) -> Set<String> {
        guard let account, !account.isEmpty,
              let arr = defaults.stringArray(forKey: namesKey(account)) else { return [] }
        return Set(arr)
    }

    /// The username those multireddits belong to, if a refresh has taught us.
    static func owner(for account: String?) -> String? {
        guard let account, !account.isEmpty else { return nil }
        let v = defaults.string(forKey: ownerKey(account))
        return (v?.isEmpty == false) ? v : nil
    }

    static func isStale(for account: String?) -> Bool {
        guard let account, !account.isEmpty else { return false }
        return Date().timeIntervalSince1970 - defaults.double(forKey: stampKey(account)) > maxAge
    }

    static func store(names: [String], owner: String?, for account: String) {
        defaults.set(names.map { $0.lowercased() }, forKey: namesKey(account))
        defaults.set(Date().timeIntervalSince1970, forKey: stampKey(account))
        if let owner, !owner.isEmpty { defaults.set(owner, forKey: ownerKey(account)) }
    }
}
