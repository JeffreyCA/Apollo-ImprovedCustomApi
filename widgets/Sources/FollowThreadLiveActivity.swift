import ActivityKit
import SwiftUI
import WidgetKit

/// The "follow thread" Live Activity UI, restored into the Reborn widget
/// extension. Renders the Lock Screen / banner presentation and the Dynamic
/// Island. Purely presentational — it draws `context.state` (pushed by
/// apollo-backend) over `context.attributes` (set when the activity started),
/// does no networking, and needs no API key, so it can't crash-loop the way the
/// stock `AthenaWidgetExtension` did. See `FollowThreadActivityAttributes`.
///
/// Structure mirrors what reverse-engineering the stock `AthenaWidgetExtension`
/// recovered: the Dynamic Island was composed of three named subviews —
/// `DynamicIslandPostScoreView`, `DynamicIslandPostTotalCommentsView`, and
/// `DynamicIslandRecentTopCommentView` — kept here as the same three pieces.
/// The stock binary used adaptive `labelColor`/`secondaryLabelColor` (not a
/// forced palette) and the Apollo mark, so this uses `.primary`/`.secondary`
/// over the system material plus the `ApolloAvatar` asset. Exact paddings/fonts
/// weren't recoverable (type-erased SwiftUI), so those are a tasteful match.
struct FollowThreadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FollowThreadActivityAttributes.self) { context in
            FollowThreadLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            islandPresentation(context)
        }
    }

    private func islandPresentation(_ context: ActivityViewContext<FollowThreadActivityAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                DynamicIslandPostScoreView(score: context.state.postScore)
            }
            DynamicIslandExpandedRegion(.trailing) {
                DynamicIslandPostTotalCommentsView(total: context.state.postTotalComments)
            }
            DynamicIslandExpandedRegion(.bottom) {
                DynamicIslandRecentTopCommentView(attributes: context.attributes, state: context.state)
            }
        } compactLeading: {
            ApolloMark()
        } compactTrailing: {
            Text(context.state.postTotalComments.abbreviated)
                .monospacedDigit().foregroundStyle(.secondary)
        } minimal: {
            ApolloMark()
        }
        .keylineTint(apolloBlue)
        .widgetURL(threadURL(context.attributes))
    }
}

// MARK: - Dynamic Island subviews (named to match the stock extension)

private struct DynamicIslandPostScoreView: View {
    let score: Int
    var body: some View {
        Label(score.abbreviated, systemImage: "arrow.up")
            .font(.caption).fontWeight(.semibold)
            .labelStyle(.titleAndIcon).monospacedDigit()
            .foregroundStyle(.primary)
    }
}

private struct DynamicIslandPostTotalCommentsView: View {
    let total: Int
    var body: some View {
        Label(total.abbreviated, systemImage: "bubble.right")
            .font(.caption)
            .labelStyle(.titleAndIcon).monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

private struct DynamicIslandRecentTopCommentView: View {
    let attributes: FollowThreadActivityAttributes
    let state: FollowThreadActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributes.postTitle)
                .font(.subheadline).fontWeight(.semibold)
                .lineLimit(1)
            if let info = ThreadCommentInfo(state) {
                HStack(spacing: 4) {
                    Text("u/\(info.author)").fontWeight(.semibold).foregroundStyle(apolloBlue)
                    Text(info.body).foregroundStyle(.secondary)
                }
                .font(.caption).lineLimit(1)
            } else {
                Text("Following — waiting for new comments…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lock Screen / banner

private struct FollowThreadLockScreenView: View {
    let attributes: FollowThreadActivityAttributes
    let state: FollowThreadActivityAttributes.ContentState

    var body: some View {
        let info = ThreadCommentInfo(state)
        VStack(alignment: .leading, spacing: 8) {
            // Header: Apollo mark + subreddit + live post stats.
            HStack(spacing: 6) {
                ApolloMark(size: 16)
                Text("r/\(attributes.subreddit)")
                    .font(.caption).fontWeight(.semibold)
                Spacer(minLength: 8)
                DynamicIslandPostScoreView(score: state.postScore)
                DynamicIslandPostTotalCommentsView(total: state.postTotalComments)
            }

            Text(attributes.postTitle)
                .font(.subheadline).fontWeight(.semibold)
                .lineLimit(2)

            Divider()

            if let info {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("u/\(info.author)")
                            .fontWeight(.semibold).foregroundStyle(apolloBlue)
                        if let score = info.score {
                            Label(score.abbreviated, systemImage: "arrow.up")
                                .labelStyle(.titleAndIcon)
                        }
                        if let age = info.age {
                            Label { Text(age, style: .relative) } icon: { Image(systemName: "clock") }
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)

                    Text(info.body)
                        .font(.caption)
                        .lineLimit(3)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Following this thread — newest comments will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .widgetURL(threadURL(attributes))
    }
}

// MARK: - Shared bits

/// Apollo's signature accent blue (matches `BlueGradient`'s top stop). Used as
/// an accent only; body text uses adaptive `.primary`/`.secondary`, matching the
/// stock extension's use of `labelColor`/`secondaryLabelColor`.
private let apolloBlue = Color(red: 0.16, green: 0.45, blue: 0.96)

/// The Apollo mascot mark (the stock activity rendered `apolloIcon`). Reuses the
/// `ApolloAvatar` asset the other Reborn widgets brand with.
private struct ApolloMark: View {
    var size: CGFloat = 18
    var body: some View {
        Image("ApolloAvatar")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// Normalized "latest comment" view model. `nil` when no comment has been
/// surfaced yet (the backend sends only post stats until a fresh top-level
/// comment turns up), so call sites can branch on presence cleanly.
private struct ThreadCommentInfo {
    let author: String
    let body: String
    let score: Int?
    let age: Date?

    init?(_ state: FollowThreadActivityAttributes.ContentState) {
        let body = state.commentBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = state.commentAuthor ?? ""
        guard !body.isEmpty || !author.isEmpty else { return nil }
        self.author = author.isEmpty ? "someone" : author
        self.body = body.isEmpty ? "(no text)" : body
        self.score = state.commentScore
        // `commentAge` is a Unix timestamp in seconds (see ContentState).
        self.age = state.commentAge.map { Date(timeIntervalSince1970: $0) }
    }
}

/// Deep link back into Apollo for the followed post, so tapping the activity
/// opens the thread. Uses the `apollo://` scheme Apollo registers.
private func threadURL(_ attributes: FollowThreadActivityAttributes) -> URL? {
    let id = attributes.postID.replacingOccurrences(of: "t3_", with: "")
    guard !id.isEmpty else { return nil }
    return URL(string: "apollo://reddit.com/r/\(attributes.subreddit)/comments/\(id)")
}
