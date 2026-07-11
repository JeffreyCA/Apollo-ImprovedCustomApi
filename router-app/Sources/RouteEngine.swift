import Foundation

/// A user-editable rule mapping web links to a native app's custom URL scheme.
///
/// `hostSuffixes` are matched against the link's host (exact or dot-boundary
/// suffix, so "reddit.com" matches "www.reddit.com" but not "notreddit.com").
/// `targetTemplate` supports two placeholders:
///   {path}  — the link's path, e.g. /r/apolloapp/comments/abc123
///   {query} — the link's query preceded by "?" when present, else empty
struct Route: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var hostSuffixes: [String]
    var targetTemplate: String
    var enabled: Bool = true

    /// Built-in defaults. Reddit → Apollo is the reason this app exists; the
    /// others make the paste-a-link tool genuinely useful on its own (and are
    /// individually toggleable). All are plain factual scheme mappings.
    static let defaults: [Route] = [
        Route(name: "Apollo (Reddit links)",
              hostSuffixes: ["reddit.com", "redd.it"],
              targetTemplate: "apollo://reddit.com{path}{query}"),
        Route(name: "YouTube app",
              hostSuffixes: ["youtube.com", "youtu.be"],
              targetTemplate: "vnd.youtube://{host}{path}{query}",
              enabled: false),
        Route(name: "Spotify app",
              hostSuffixes: ["open.spotify.com"],
              targetTemplate: "spotify://{path}",
              enabled: false),
    ]

    init(id: UUID = UUID(), name: String, hostSuffixes: [String], targetTemplate: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.hostSuffixes = hostSuffixes
        self.targetTemplate = targetTemplate
        self.enabled = enabled
    }

    func matches(host: String) -> Bool {
        let host = host.lowercased()
        return hostSuffixes.contains { suffix in
            let suffix = suffix.lowercased()
            return host == suffix || host.hasSuffix("." + suffix)
        }
    }

    func target(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        let host = components.host ?? ""
        let rendered = targetTemplate
            .replacingOccurrences(of: "{host}", with: host)
            .replacingOccurrences(of: "{path}", with: path)
            .replacingOccurrences(of: "{query}", with: query)
        return URL(string: rendered)
    }
}

enum RouteEngine {
    /// Bounce domains this app claims via Universal Links, mapped to the
    /// canonical web host their paths belong to. A tap on
    /// https://open.apolloreborn.app/r/... arrives here as a Universal Link;
    /// we first reconstruct https://reddit.com/r/... and then route it like
    /// any other link.
    static let bounceHosts: [String: String] = [
        "open.apolloreborn.app": "reddit.com",
    ]

    /// Rewrites a bounce-domain URL back to its canonical web form.
    /// Returns the URL unchanged when it isn't a bounce link.
    static func canonicalize(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              let canonicalHost = bounceHosts[host],
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        components.host = canonicalHost
        components.port = nil
        return components.url ?? url
    }

    /// The first enabled route matching the URL's host, if any.
    static func route(for url: URL, in routes: [Route]) -> Route? {
        guard let host = url.host else { return nil }
        return routes.first { $0.enabled && $0.matches(host: host) }
    }
}
