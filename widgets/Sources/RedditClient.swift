import Foundation
import os

let rwLog = Logger(subsystem: "com.christianselig.Apollo.RebornWidgets", category: "widget")

/// URLSession with tight timeouts so the widget never hangs past WidgetKit's
/// timeline budget.
///
/// Caching is fully disabled: a widget must always show FRESH listings. With the
/// default in-memory `URLCache`, repeated fetches of the same listing URL (same
/// subreddit + sort) could be served from cache, which looked like the widget
/// being "stuck" on the same posts and ignoring refresh.
let rwSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 8
    cfg.timeoutIntervalForResource = 12
    cfg.waitsForConnectivity = false
    cfg.urlCache = nil
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: cfg)
}()

/// Minimal Reddit client with two token tiers:
///
///   * **app-only** (`grant_type=...installed_client`) — needs only the client
///     id and reads every public listing: subreddits, r/popular, r/all, other
///     people's public multireddits. This is what every widget used before.
///   * **account** (`grant_type=refresh_token`) — present only when the setup
///     code was copied *with account*. It's what Home and the user's own
///     (private) multireddits need; public sources keep using the app-only
///     token so a revoked account never breaks them.
///
/// Validated by hand:
///   POST https://www.reddit.com/api/v1/access_token   (Basic clientID:secret-or-empty)
///   GET  https://oauth.reddit.com/r/showerthoughts/top?t=day&limit=N
///   GET  https://oauth.reddit.com/hot                   (home; user token)
///   GET  https://oauth.reddit.com/me/m/<multi>/hot      (own multi; user token)
///   GET  https://oauth.reddit.com/user/<u>/m/<multi>/hot (public multi; either token)
///   GET  https://oauth.reddit.com/api/multi/mine        (user token)
/// Reddit does NOT rotate refresh tokens on use, so the widget refreshing its
/// own access token never invalidates the one Apollo itself holds.
struct RedditClient {
    let clientID: String
    let userAgent: String
    /// Client secret for "web app" (confidential) API keys; empty for the
    /// usual "installed app" keys, matching how Apollo itself authenticates.
    var clientSecret: String = ""
    var refreshToken: String? = nil
    var username: String? = nil

    init(clientID: String, userAgent: String, clientSecret: String = "",
         refreshToken: String? = nil, username: String? = nil) {
        self.clientID = clientID
        self.userAgent = userAgent
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.username = username
    }

    init(code: SetupCode) {
        self.init(clientID: code.clientID, userAgent: code.resolvedUserAgent,
                  clientSecret: code.clientSecret ?? "",
                  refreshToken: code.hasAccount ? code.refreshToken : nil,
                  username: code.username)
    }

    var hasAccount: Bool { !(refreshToken ?? "").isEmpty }

    /// Stable id of the signed-in account for per-account caches (never the
    /// raw token). Nil without an account.
    var accountKey: String? {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        return String(fnv1a("\(clientID):\(refreshToken)"), radix: 36)
    }

    enum ClientError: Error {
        case http(Int), badResponse, noToken
        /// The source needs a user token and the setup code has none.
        case needsAccount
        /// Reddit refused the refresh token (revoked / password changed).
        case accountRejected
    }

    // MARK: Token cache (per-extension UserDefaults; no cross-process sharing)

    private static let defaults = UserDefaults.standard
    private static let tokenKey = "rw.appOnlyToken"
    private static let tokenExpiryKey = "rw.appOnlyTokenExpiry"
    private static let tokenClientKey = "rw.appOnlyTokenClient"
    private static let deviceIDKey = "rw.deviceID"
    private static let userTokenKey = "rw.userToken"
    private static let userTokenExpiryKey = "rw.userTokenExpiry"
    private static let userTokenAccountKey = "rw.userTokenAccount"

    /// Stable per-install device id required by the installed_client grant.
    private static var deviceID: String {
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let new = UUID().uuidString
        defaults.set(new, forKey: deviceIDKey)
        return new
    }

    private func cachedToken() -> String? {
        let d = Self.defaults
        guard d.string(forKey: Self.tokenClientKey) == clientID,
              let token = d.string(forKey: Self.tokenKey) else { return nil }
        let expiry = d.double(forKey: Self.tokenExpiryKey)
        // Refresh a little early to avoid edge-of-expiry failures.
        guard expiry - 120 > Date().timeIntervalSince1970 else { return nil }
        return token
    }

    private func storeToken(_ token: String, expiresIn: Double) {
        let d = Self.defaults
        d.set(token, forKey: Self.tokenKey)
        d.set(clientID, forKey: Self.tokenClientKey)
        d.set(Date().timeIntervalSince1970 + expiresIn, forKey: Self.tokenExpiryKey)
    }

    private func cachedUserToken() -> String? {
        let d = Self.defaults
        guard let accountKey, d.string(forKey: Self.userTokenAccountKey) == accountKey,
              let token = d.string(forKey: Self.userTokenKey) else { return nil }
        guard d.double(forKey: Self.userTokenExpiryKey) - 120 > Date().timeIntervalSince1970 else { return nil }
        return token
    }

    private func storeUserToken(_ token: String, expiresIn: Double) {
        let d = Self.defaults
        d.set(token, forKey: Self.userTokenKey)
        d.set(accountKey, forKey: Self.userTokenAccountKey)
        d.set(Date().timeIntervalSince1970 + expiresIn, forKey: Self.userTokenExpiryKey)
    }

    // MARK: OAuth

    private func tokenRequest(body: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // HTTP Basic: clientID as username, the secret (empty for installed
        // apps) as password — the same shape Apollo's own RedditKit sends.
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        return req
    }

    private struct TokenResponse: Codable { let access_token: String; let expires_in: Double }

    private func fetchToken() async throws -> String {
        let body = "grant_type=https://oauth.reddit.com/grants/installed_client&device_id=\(Self.deviceID)"
        let (data, resp) = try await rwSession.data(for: tokenRequest(body: body))
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else { throw ClientError.http(http.statusCode) }
        guard let tr = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ClientError.noToken
        }
        storeToken(tr.access_token, expiresIn: tr.expires_in)
        return tr.access_token
    }

    private func token() async throws -> String {
        if let cached = cachedToken() { return cached }
        return try await fetchToken()
    }

    /// Mint a user access token from the account's refresh token.
    private func fetchUserToken() async throws -> String {
        guard let refreshToken, !refreshToken.isEmpty else { throw ClientError.needsAccount }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        let body = "grant_type=refresh_token&refresh_token=\(encoded)"
        let (data, resp) = try await rwSession.data(for: tokenRequest(body: body))
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        // Reddit answers a revoked/foreign refresh token with 400 invalid_grant
        // (401 for a bad client id/secret pairing); both mean "re-copy the code".
        if http.statusCode == 400 || http.statusCode == 401 {
            rwLog.error("user token refresh → HTTP \(http.statusCode)")
            throw ClientError.accountRejected
        }
        guard http.statusCode == 200 else { throw ClientError.http(http.statusCode) }
        guard let tr = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ClientError.noToken
        }
        storeUserToken(tr.access_token, expiresIn: tr.expires_in)
        return tr.access_token
    }

    private func userToken() async throws -> String {
        if let cached = cachedUserToken() { return cached }
        return try await fetchUserToken()
    }

    /// The bearer for a source: account tier for personal sources, app-only for
    /// everything public (so a dead account never takes r/aww down with it).
    private func bearer(for source: FeedSource) async throws -> String {
        if source.needsAccount {
            guard hasAccount else { throw ClientError.needsAccount }
            return try await userToken()
        }
        return try await token()
    }

    // MARK: Data

    /// Posts from any `FeedSource` at the given sort.
    func posts(source: FeedSource, sort: WidgetSort, limit: Int = 25,
               allowNSFW: Bool = false) async throws -> [RedditPost] {
        let bearer = try await bearer(for: source)
        // Built from sanitized names, but never force-unwrap: a nil URL must
        // surface as an error, not a crash (a crashing extension poisons
        // WidgetKit's enumeration of every widget).
        guard var comps = URLComponents(string: "https://oauth.reddit.com\(source.listingPath)/\(sort.path)") else {
            throw ClientError.badResponse
        }
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "raw_json", value: "1"),
        ]
        if let t = sort.timeWindow { items.append(URLQueryItem(name: "t", value: t)) }
        // Hint Reddit to include 18+ listings (best-effort; full NSFW access for
        // dedicated 18+ subs generally needs a logged-in user token, not this
        // app-only grant).
        if allowNSFW { items.append(URLQueryItem(name: "include_over_18", value: "1")) }
        comps.queryItems = items
        guard let url = comps.url else { throw ClientError.badResponse }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bearer \(bearer)", forHTTPHeaderField: "Authorization")

        rwLog.log("fetch \(url.absoluteString, privacy: .public)")
        let (data, resp) = try await rwSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard http.statusCode == 200 else {
            rwLog.error("fetch \(source.listingPath, privacy: .public)/\(sort.path, privacy: .public) → HTTP \(http.statusCode)")
            throw ClientError.http(http.statusCode)
        }
        let posts = Self.parseListing(data, allowNSFW: allowNSFW)
        let firstIDs = posts.prefix(3).map { $0.id }.joined(separator: ",")
        let window = sort.timeWindow ?? "-"
        rwLog.log("fetched \(source.label, privacy: .public) sort=\(sort.path, privacy: .public) t=\(window, privacy: .public) → \(posts.count) posts [\(firstIDs, privacy: .public)]")
        return posts
    }

    /// Posts from one subreddit (the fixed-subreddit widgets: Jokes, Showerthoughts).
    func topPosts(subreddit: String, sort: WidgetSort, limit: Int = 25,
                  allowNSFW: Bool = false) async throws -> [RedditPost] {
        let sub = RedditPost.normalizeSubreddit(subreddit)
        guard !sub.isEmpty else { throw ClientError.badResponse }
        return try await posts(source: .subreddits([sub]), sort: sort, limit: limit, allowNSFW: allowNSFW)
    }

    /// Learn the signed-in user's multireddits (names + owner) into `OwnMultis`
    /// when the cache is missing or old. No-op without an account; failures
    /// are logged and simply leave the cache as it was.
    func refreshOwnMultisIfStale() async {
        guard let accountKey, OwnMultis.isStale(for: accountKey) else { return }
        do {
            let bearer = try await userToken()
            guard let url = URL(string: "https://oauth.reddit.com/api/multi/mine?raw_json=1") else { return }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await rwSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                rwLog.error("multi/mine failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                return
            }
            var names: [String] = []
            var owner: String? = username
            for item in list {
                guard let d = item["data"] as? [String: Any],
                      let name = d["name"] as? String, !name.isEmpty else { continue }
                names.append(name)
                // "/user/<owner>/m/<name>/" — the owner is our username.
                if owner == nil, let path = d["path"] as? String {
                    let segs = path.split(separator: "/")
                    if segs.count >= 2, segs[0] == "user" { owner = String(segs[1]) }
                }
            }
            OwnMultis.store(names: names, owner: owner, for: accountKey)
            rwLog.log("multi/mine → \(names.count) multireddit(s)")
        } catch {
            rwLog.error("multi/mine: \(String(describing: error), privacy: .public)")
        }
    }

    /// A subreddit's icon URL + brand color hex from /about (best-effort).
    func subredditAbout(_ subreddit: String) async throws -> (icon: String?, colorHex: String?) {
        let bearer = try await token()
        let sub = RedditPost.normalizeSubreddit(subreddit)
        // Best-effort endpoint — a bad/empty sub just yields no icon, no crash.
        guard !sub.isEmpty, let url = URL(string: "https://oauth.reddit.com/r/\(sub)/about?raw_json=1") else {
            return (nil, nil)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await rwSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return (nil, nil) }

        var icon: String?
        for key in ["community_icon", "icon_img"] {
            if let u = d[key] as? String, u.hasPrefix("http") { icon = u; break }
        }
        var colorHex: String?
        for key in ["primary_color", "key_color"] {
            if let c = d[key] as? String, c.hasPrefix("#"), c.count == 7 { colorHex = c; break }
        }
        return (icon, colorHex)
    }

    /// Parse a Reddit listing into posts, applying widget content-eligibility
    /// rules (PRD §10): skip stickied, NSFW, spoiler, and removed/deleted posts,
    /// and anything with an empty title. These widgets are a Home Screen surface
    /// that other people may see, so unsafe content is filtered for every widget.
    static func parseListing(_ data: Data, allowNSFW: Bool = false) -> [RedditPost] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let children = dataObj["children"] as? [[String: Any]] else { return [] }

        var out: [RedditPost] = []
        for child in children {
            guard let post = child["data"] as? [String: Any],
                  let title = post["title"] as? String,
                  isEligible(post, title: title, allowNSFW: allowNSFW) else { continue }

            let postHint = post["post_hint"] as? String ?? ""
            let isImage = postHint == "image"
                || (post["url"] as? String).map { Self.looksLikeImage($0) } ?? false
            let id = Self.stablePostID(from: post)

            out.append(RedditPost(
                id: id,
                title: title,
                author: post["author"] as? String ?? "",
                subreddit: post["subreddit"] as? String ?? "",
                score: post["score"] as? Int ?? 0,
                numComments: post["num_comments"] as? Int ?? 0,
                permalink: post["permalink"] as? String ?? "",
                selftext: post["selftext"] as? String ?? "",
                thumbnailURL: Self.thumbnail(from: post),
                imageURL: Self.previewImage(from: post),
                isImagePost: isImage,
                created: post["created_utc"] as? Double))
        }
        return out
    }

    private static func stablePostID(from post: [String: Any]) -> String {
        if let id = post["id"] as? String, !id.isEmpty { return id }
        if let permalink = post["permalink"] as? String, !permalink.isEmpty { return "permalink:\(permalink)" }
        if let url = post["url"] as? String, !url.isEmpty { return "url:\(url)" }
        let title = post["title"] as? String ?? ""
        let author = post["author"] as? String ?? ""
        let created = post["created_utc"] as? Double ?? 0
        return "fallback:\(fnv1a("\(title)|\(author)|\(created)"))"
    }

    /// Content-eligibility gate for a single listing child (PRD §10).
    private static func isEligible(_ post: [String: Any], title: String, allowNSFW: Bool) -> Bool {
        // Non-empty, non-removed/deleted title.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[removed]" || trimmed == "[deleted]" { return false }
        // Stickied announcements aren't interesting content.
        if post["stickied"] as? Bool ?? false { return false }
        // NSFW is hidden unless this widget opted in; spoiler always hidden.
        if !allowNSFW, post["over_18"] as? Bool ?? false { return false }
        if post["spoiler"] as? Bool ?? false { return false }
        // Mod-removed / author-deleted posts.
        if (post["removed_by_category"] as? String)?.isEmpty == false { return false }
        if (post["author"] as? String) == "[deleted]" { return false }
        if (post["selftext"] as? String) == "[removed]" { return false }
        return true
    }

    private static func looksLikeImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp"].contains { lower.hasSuffix($0) }
    }

    /// Small square-ish thumbnail for feed rows.
    private static func thumbnail(from post: [String: Any]) -> String? {
        if let t = post["thumbnail"] as? String, t.hasPrefix("http") { return t }
        // Fall back to the smallest preview resolution.
        if let res = previewResolutions(from: post), let first = res.first,
           let u = first["url"] as? String { return u }
        return nil
    }

    /// A medium preview resolution (≤ ~640px) suitable for Photo/Single Post.
    private static func previewImage(from post: [String: Any]) -> String? {
        guard let res = previewResolutions(from: post) else { return nil }
        // Pick the largest resolution at or under 640px wide, else the largest.
        let sorted = res.compactMap { r -> (Int, String)? in
            guard let w = r["width"] as? Int, let u = r["url"] as? String else { return nil }
            return (w, u)
        }.sorted { $0.0 < $1.0 }
        if let pick = sorted.last(where: { $0.0 <= 640 }) ?? sorted.last {
            return pick.1
        }
        return nil
    }

    private static func previewResolutions(from post: [String: Any]) -> [[String: Any]]? {
        guard let preview = post["preview"] as? [String: Any],
              let images = preview["images"] as? [[String: Any]],
              let first = images.first,
              let resolutions = first["resolutions"] as? [[String: Any]] else { return nil }
        return resolutions
    }
}
