import SwiftUI
import WidgetKit

/// Single Post: top post of a subreddit, full-bleed image with a title scrim.
struct SinglePostWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if isAccessoryFamily(family) {
            AccessoryPostView(entry: entry, label: "Post", icon: "doc.text.image")
        } else {
            homeBody
        }
    }

    private var homeBody: some View {
        WidgetShell(entry: entry) {
            imageBackground(entry, fallback: BlueGradient())
        } content: { renders in
            let render = renders[0]
            // Adaptive: image posts get the photo-card treatment; text posts
            // (showerthoughts, jokes, any self-post) render title + body on the
            // gradient, like Apollo's text widgets.
            if render.imageData != nil {
                imageContent(render.post)
                    .modifier(AccentedPhotoBackground(data: render.imageData))
            } else {
                textContent(render.post)
            }
        }
    }

    private func imageContent(_ post: RedditPost) -> some View {
        let caption = entry.caption
        return VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            if caption.showsTitle {
                Text(post.title)
                    .font(.system(size: family == .systemSmall ? 14 : 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(family == .systemSmall ? 3 : 4)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
            if caption.showsStats {
                StatsLine(post: post,
                          display: caption.density,
                          showSubreddit: family != .systemSmall,
                          showComments: family != .systemSmall)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.top, 30)
        .background(alignment: .bottom) {
            // Only scrim when there's overlay text, so "None" is a clean image.
            if caption != .hidden {
                LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.85)],
                               startPoint: .center, endPoint: .bottom)
                    .padding(-24)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            NextOverlayButton(rotationKey: entry.rotationKey, kind: "SinglePostWidget")
                .offset(y: -6)
        }
        .opensInApollo(post)
    }

    private func textContent(_ post: RedditPost) -> some View {
        // Text posts always show their title (a text widget with no text would
        // be blank); caption controls stats density + the body preview.
        let caption = entry.caption
        return VStack(alignment: .leading, spacing: 5) {
            WidgetHeader(label: "r/\(post.subreddit)",
                         trailing: AnyView(NextButton(rotationKey: entry.rotationKey,
                                                      kind: "SinglePostWidget")))
            Spacer(minLength: 2)
            Text(post.title)
                .font(.system(size: family == .systemSmall ? 14 : 17, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(family == .systemLarge ? 6 : (family == .systemSmall ? 5 : 4))
            if caption.showsPreview, !post.selftext.isEmpty {
                Text(post.selftext)
                    .font(.system(size: family == .systemLarge ? 15 : 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .minimumScaleFactor(0.7)
                    .lineLimit(family == .systemLarge ? 6 : 3)
            }
            Spacer(minLength: 2)
            if caption.showsStats {
                // Subreddit is already in the header, so omit it here.
                StatsLine(post: post, display: caption.density, showSubreddit: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opensInApollo(post)
    }
}

/// Photo: full-bleed top image of a subreddit, minimal chrome.
struct PhotoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    // Dim the photo in StandBy Night Mode so the caption stays legible.
    @Environment(\.isLuminanceReduced) private var dimmed
    let entry: WidgetEntry

    var body: some View {
        WidgetShell(entry: entry) {
            imageBackground(entry, fallback: BlueGradient())
                .overlay(dimmed ? Color.black.opacity(0.45) : Color.clear)
        } content: { renders in
            let post = renders[0].post
            let caption = entry.caption
            // Stats row is too cramped on the small family — show it only on
            // medium/large. Title shows whenever caption isn't "None".
            let showStats = caption.showsStats && family != .systemSmall
            let hasOverlayText = caption.showsTitle || showStats

            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                if caption.showsTitle {
                    Text(post.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showStats {
                    StatsLine(post: post, display: caption.density)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(alignment: .bottom) {
                // Only darken the bottom when there's text to keep legible.
                if hasOverlayText {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        .padding(-24)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                NextOverlayButton(rotationKey: entry.rotationKey, kind: "PhotoWidget")
                    .offset(y: -6)
            }
            .modifier(AccentedPhotoBackground(data: renders[0].imageData))
            .opensInApollo(post)
        }
    }
}

/// Feed: a scrolling-style list of a subreddit's top posts. Each row links to
/// its post in Apollo.
struct FeedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: WidgetEntry

    /// How many rows to show. A medium is short, so it always shows 2 (the rows
    /// compress/expand to fit). A large varies hugely by device, so we fit by
    /// measured height — fixed counts either clip on small phones or leave a
    /// black void on a Pro Max.
    private func rowCount(height: CGFloat, available: Int) -> Int {
        guard available > 0 else { return 0 }
        // Compact rows are shorter, so more of them fit.
        let rowHeight: CGFloat = entry.feedCompact ? 40 : 58
        if family == .systemMedium { return min(entry.feedCompact ? 3 : 2, available) }
        let n = Int((height - 14) / rowHeight)  // ≈ header + n·(row+divider)
        return max(2, min(n, available))
    }

    var body: some View {
        let palette = FeedPalette(scheme: colorScheme)
        WidgetShell(entry: entry) {
            palette.background
        } content: { renders in
            GeometryReader { geo in
                let label = entry.sourceLabel ?? "r/\(renders.first?.post.subreddit ?? "")"
                let rows = Array(renders.prefix(rowCount(height: geo.size.height,
                                                         available: renders.count)))
                VStack(alignment: .leading, spacing: 0) {
                    WidgetHeader(label: label,
                                 tint: palette.accent,
                                 trailing: AnyView(ReloadButton(kind: "FeedWidget")))
                        .padding(.bottom, 6)
                    ForEach(Array(rows.enumerated()), id: \.element.post.id) { idx, render in
                        // Rows share leftover space equally so the list fills the
                        // widget instead of leaving a black void at the bottom.
                        rowLink(render, palette: palette).frame(maxHeight: .infinity)
                        if idx != rows.count - 1 {
                            Divider().overlay(palette.separator).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private func rowLink(_ render: RenderPost, palette: FeedPalette) -> some View {
        if let url = render.post.apolloURL {
            Link(destination: url) { row(render, palette: palette) }
        } else {
            row(render, palette: palette)
        }
    }

    private func row(_ render: RenderPost, palette: FeedPalette) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(render.post.title)
                    .font(.system(size: family == .systemMedium ? 13 : 14, weight: .semibold))
                    .foregroundStyle(palette.title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                StatsLine(post: render.post,
                          foreground: palette.metadata,
                          font: .system(size: 12, weight: .regular))
            }
            // Keep the thumbnail off the trailing edge so it clears the widget's
            // rounded corner instead of being clipped diagonally.
            Spacer(minLength: 8)
            if let img = imageFromData(render.imageData) {
                img.accentedPhotoResizable().aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct FeedPalette {
    let background: Color
    let title: Color
    let metadata: Color
    let separator: Color
    let accent: Color

    init(scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0.11, green: 0.12, blue: 0.14)
            title = Color.white.opacity(0.94)
            metadata = Color(red: 0.70, green: 0.73, blue: 0.78)
            separator = Color.white.opacity(0.12)
            accent = Color(red: 0.40, green: 0.62, blue: 1.0)
        } else {
            background = Color(red: 0.98, green: 0.985, blue: 0.995)
            title = Color(red: 0.11, green: 0.12, blue: 0.14)
            metadata = Color(red: 0.43, green: 0.47, blue: 0.54)
            separator = Color.black.opacity(0.10)
            accent = Color(red: 0.16, green: 0.42, blue: 0.88)
        }
    }
}
