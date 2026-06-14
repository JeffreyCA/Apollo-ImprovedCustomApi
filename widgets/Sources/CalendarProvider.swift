import WidgetKit
import Foundation

// MARK: - Daily "photo of the day" selection

/// Picks one stable photo per day for the Calendar widget and guarantees it
/// neither changes during the day nor repeats a recent day.
///
/// Why not normal widget rotation: the other widgets rotate on a wall-clock
/// slot so a glance later shows something new. The Calendar widget is the
/// opposite — it must LOCK one image for the whole day and only change at
/// midnight. So selection is fully deterministic and, crucially, **persisted**:
///
///   1. If today's pick was already chosen (stored), reuse it verbatim. This is
///      what makes it immune to Reddit's live listing reordering — once locked,
///      the exact post (and its image URL) is frozen for that date.
///   2. Otherwise order the image candidates by a STABLE field (post id), so the
///      order doesn't depend on the volatile listing order.
///   3. Start at a deterministic index = hash(config + date) % count, then walk
///      forward to the first candidate whose id isn't in the recent-use history
///      (dedup). If the sub is too small and everything's been used, fall back
///      to the least-recently-used candidate.
///   4. Persist the chosen post for that date and append it to history.
enum DailyPhoto {
    private static let defaults = UserDefaults.standard
    /// How many days of history to keep for dedup. Tiny storage; one short
    /// string per day. ~4 months means a 120+ image sub never repeats.
    private static let historyLimit = 150

    private static func pickKey(_ cfg: String, _ day: String) -> String { "rw.cal.pick.\(cfg).\(day)" }
    private static func historyKey(_ cfg: String) -> String { "rw.cal.hist.\(cfg)" }

    /// `yyyy-MM-dd` in the user's current calendar/timezone — the per-day key.
    static func dayString(_ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: stored locked pick

    private static func storedPick(_ cfg: String, _ day: String) -> RedditPost? {
        guard let data = defaults.data(forKey: pickKey(cfg, day)) else { return nil }
        return try? JSONDecoder().decode(RedditPost.self, from: data)
    }

    private static func storePick(_ post: RedditPost, _ cfg: String, _ day: String) {
        if let data = try? JSONEncoder().encode(post) {
            defaults.set(data, forKey: pickKey(cfg, day))
        }
    }

    // MARK: dedup history  (ordered [day, id] pairs, most-recent last)

    private struct HistoryEntry: Codable { let day: String; let id: String }

    private static func history(_ cfg: String) -> [HistoryEntry] {
        guard let data = defaults.data(forKey: historyKey(cfg)),
              let h = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return h
    }

    private static func record(_ id: String, _ cfg: String, _ day: String) {
        var h = history(cfg).filter { $0.day != day }   // one entry per day
        h.append(HistoryEntry(day: day, id: id))
        if h.count > historyLimit { h.removeFirst(h.count - historyLimit) }
        if let data = try? JSONEncoder().encode(h) { defaults.set(data, forKey: historyKey(cfg)) }
    }

    /// The locked photo for `day`, choosing (and persisting) one if needed.
    /// `pool` is the freshly fetched candidate set; ignored once a day is locked.
    static func pick(cfg: String, day: String, pool: [RedditPost]) -> RedditPost? {
        // 1. Already locked → return verbatim (stable all day, churn-proof).
        if let stored = storedPick(cfg, day) { return stored }

        // 2. Stable candidate order, image posts only.
        let candidates = pool.filter { $0.isImagePost && ($0.imageURL != nil || $0.thumbnailURL != nil) }
                             .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else { return nil }

        let hist = history(cfg)
        let used = Set(hist.map { $0.id })

        // 3. Deterministic start index, then walk to first un-used candidate.
        let start = Int(fnv1a("\(cfg)|\(day)") % UInt64(candidates.count))
        var chosen: RedditPost?
        for i in 0..<candidates.count {
            let cand = candidates[(start + i) % candidates.count]
            if !used.contains(cand.id) { chosen = cand; break }
        }

        // 3b. Pool exhausted (small sub): reuse the least-recently-used candidate
        // — deterministic, oldest history position wins, id breaks ties.
        if chosen == nil {
            var lastUsedIndex: [String: Int] = [:]
            for (i, e) in hist.enumerated() { lastUsedIndex[e.id] = i }
            chosen = candidates.min {
                let a = lastUsedIndex[$0.id] ?? -1, b = lastUsedIndex[$1.id] ?? -1
                return a != b ? a < b : $0.id < $1.id
            }
        }

        guard let post = chosen else { return nil }
        // 4. Lock it for this date and remember it for future dedup.
        storePick(post, cfg, day)
        record(post.id, cfg, day)
        return post
    }
}

// MARK: - Calendar widget timeline

private func calendarStyle(_ s: RebornDateStyle) -> CalendarStyle {
    switch s {
    case .rounded: return .rounded
    case .serif: return .serif
    case .mono: return .mono
    case .condensed: return .condensed
    case .stamp: return .stamp
    @unknown default: return .rounded
    }
}

struct CalendarProvider: IntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = CalendarConfigurationIntent

    /// How many upcoming days to pre-render. Each gets its own locked pick +
    /// downloaded image, so the photo flips at midnight even if WidgetKit never
    /// reloads us on time. Kept small to stay within the image-download budget.
    private let windowDays = 4

    /// A "photo of the day" is conceptually the best image, so the Calendar
    /// always uses Top: This Week — no sort option to keep it simple.
    static let calendarSort: WidgetSort = .topWeek

    func placeholder(in context: Context) -> WidgetEntry {
        var e = WidgetEntry.sample([WidgetSample.feed[4]])
        e.calendarStyle = .rounded
        return e
    }

    func getSnapshot(for configuration: Intent, in context: Context,
                     completion: @escaping (WidgetEntry) -> Void) {
        let style = calendarStyle(configuration.dateStyle)
        let showTitle = configuration.showTitle?.boolValue ?? false
        if context.isPreview {
            var e = WidgetEntry.sample([WidgetSample.feed[4]])
            e.calendarStyle = style; e.calendarShowTitle = showTitle
            completion(e); return
        }
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        let cfg = configKey(sub: sub, sort: Self.calendarSort)
        let today = DailyPhoto.dayString(Date())
        if let locked = lockedPostForSnapshot(cfg: cfg, day: today, sub: sub) {
            var e = WidgetEntry(date: Date(), state: .posts([RenderPost(post: locked, imageData: nil)]))
            e.calendarStyle = style; e.calendarShowTitle = showTitle
            completion(e)
        } else {
            var e = WidgetEntry.sample([WidgetSample.feed[4]])
            e.calendarStyle = style; e.calendarShowTitle = showTitle
            completion(e)
        }
    }

    func getTimeline(for configuration: Intent, in context: Context,
                     completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let sub = resolvedSubreddit(configuration.subreddit, default: "EarthPorn")
        let sort = Self.calendarSort
        let style = calendarStyle(configuration.dateStyle)
        let showTitle = configuration.showTitle?.boolValue ?? false
        let cfg = configKey(sub: sub, sort: sort)

        runPostTimeline(
            code: configuration.setupCode, cacheKey: "calpool.\(sub)",
            fetch: { try await $0.topPosts(subreddit: sub, sort: sort, limit: 50).filter { $0.isImagePost } },
            assemble: { pool in
                await assembleCalendar(pool, cfg: cfg, style: style, showTitle: showTitle,
                                       windowDays: windowDays)
            },
            completion: completion)
    }

    private func configKey(sub: String, sort: WidgetSort) -> String {
        "cal.\(sub.lowercased()).\(sort.path)\(sort.timeWindow ?? "")"
    }

    /// For the snapshot we only want a previously-locked pick; never lock a new
    /// one off the snapshot path (no pool here).
    private func lockedPostForSnapshot(cfg: String, day: String, sub: String) -> RedditPost? {
        // DailyPhoto.pick with an empty pool returns the stored pick if locked,
        // else nil — exactly the read-only behaviour we want here.
        DailyPhoto.pick(cfg: cfg, day: day, pool: [])
    }
}

/// Build the Calendar timeline: one locked entry per upcoming day, each with its
/// downloaded image, then reload after the window.
func assembleCalendar(_ pool: [RedditPost], cfg: String, style: CalendarStyle,
                      showTitle: Bool, windowDays: Int) async -> Timeline<WidgetEntry> {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())

    // Pick (and lock) a post for each day in the window. Picking day N before
    // day N+1 means N is in N+1's dedup history, so the window never repeats.
    var dayPosts: [(date: Date, post: RedditPost)] = []
    for i in 0..<max(1, windowDays) {
        guard let date = cal.date(byAdding: .day, value: i, to: today) else { continue }
        let day = DailyPhoto.dayString(date)
        if let post = DailyPhoto.pick(cfg: cfg, day: day, pool: pool) {
            dayPosts.append((date, post))
        }
    }
    guard !dayPosts.isEmpty else {
        return singleEntry(.error("No photos available for this subreddit."), refreshIn: 60 * 60)
    }

    // Download each day's image (small set, within budget), order preserved.
    let renders = await downloadImages(dayPosts.map { $0.post },
                                       keyPath: { $0.imageURL ?? $0.thumbnailURL },
                                       maxPixel: 900)

    var entries: [WidgetEntry] = []
    for (i, dp) in dayPosts.enumerated() {
        // First entry uses `now` so it's never in the future; later entries land
        // on their day's midnight, so the overlay date rolls over correctly.
        let entryDate = i == 0 ? Date() : dp.date
        var e = WidgetEntry(date: entryDate, state: .posts([renders[i]]))
        e.calendarStyle = style
        e.calendarShowTitle = showTitle
        entries.append(e)
    }

    // Reload after the last pre-rendered day to roll the window forward.
    let reloadAfter = cal.date(byAdding: .day, value: max(1, windowDays), to: today) ?? Date().addingTimeInterval(86_400)
    return Timeline(entries: entries, policy: .after(reloadAfter))
}
