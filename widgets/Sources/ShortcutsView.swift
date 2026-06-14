import SwiftUI
import WidgetKit

/// Apple-Shortcuts-style subreddit tiles: a colored rounded card per subreddit
/// with its icon top-left and name bottom-left. Tapping opens the sub in Apollo.
struct ShortcutsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: ShortcutsEntry

    private var columns: Int { 2 }
    private var maxItems: Int {
        switch family {
        case .systemLarge: return 8   // 2 × 4
        case .systemMedium: return 6  // 2 × 3
        default: return 4             // 2 × 2 (small)
        }
    }

    var body: some View {
        Group {
            if entry.needsConfig {
                MessageView(icon: "square.grid.2x2",
                            title: "Add subreddits",
                            detail: "Choose Custom, then enter a comma-separated list, e.g. aww, apple, EarthPorn.")
            } else {
                grid
            }
        }
        .containerBackground(for: .widget) { palette.background }
    }

    private var grid: some View {
        let items = Array(entry.items.prefix(maxItems))
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0 ..< min($0 + columns, items.count)])
        }
        let spacing = family == .systemMedium ? CGFloat(8) : CGFloat(10)
        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.label) { item in
                        if family == .systemMedium {
                            compactTile(item)
                        } else {
                            tile(item)
                        }
                    }
                    // Pad a short final row so tiles keep their width.
                    if row.count < columns {
                        ForEach(0 ..< (columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func compactTile(_ item: ShortcutItem) -> some View {
        let body = Text(item.label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tileColor(item), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        if let url = item.apolloURL {
            Link(destination: url) { body }
        } else {
            body
        }
    }

    @ViewBuilder private func tile(_ item: ShortcutItem) -> some View {
        let body = VStack(alignment: .leading, spacing: 0) {
            avatar(item)
            Spacer(minLength: 4)
            Text(item.label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tileColor(item), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        if let url = item.apolloURL {
            Link(destination: url) { body }
        } else {
            body
        }
    }

    private func avatar(_ item: ShortcutItem) -> some View {
        let size: CGFloat = 30
        return Group {
            if let img = imageFromData(item.iconData) {
                img.accentedPhotoResizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(.white.opacity(0.25))
                    Text(String(item.label.prefix(1)).uppercased())
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
    }

    /// Brand color from the subreddit when available, else a stable palette pick.
    private func tileColor(_ item: ShortcutItem) -> Color {
        if let c = Color(hex: item.colorHex) { return c }
        let palette: [Color] = [
            Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.62, blue: 0.20),
            Color(red: 0.30, green: 0.72, blue: 0.40), Color(red: 0.90, green: 0.35, blue: 0.35),
            Color(red: 0.55, green: 0.40, blue: 0.92), Color(red: 0.20, green: 0.68, blue: 0.70),
            Color(red: 0.92, green: 0.45, blue: 0.62), Color(red: 0.45, green: 0.50, blue: 0.95),
        ]
        // Shared stable FNV-1a (not Swift's per-process-randomized hashValue) so
        // a tile's fallback color is the same every launch.
        return palette[Int(fnv1a(item.label.lowercased()) % UInt64(palette.count))]
    }

    private var palette: ShortcutsPalette {
        ShortcutsPalette(scheme: colorScheme)
    }
}

private struct ShortcutsPalette {
    let background: Color

    init(scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0.09, green: 0.10, blue: 0.12)
        } else {
            background = Color(red: 0.86, green: 0.95, blue: 0.98)
        }
    }
}

// MARK: - Apollo Quick Actions

struct ApolloQuickActionsEntry: TimelineEntry {
    let date: Date
}

struct ApolloQuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ApolloQuickActionsEntry {
        ApolloQuickActionsEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ApolloQuickActionsEntry) -> Void) {
        completion(ApolloQuickActionsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ApolloQuickActionsEntry>) -> Void) {
        completion(Timeline(entries: [ApolloQuickActionsEntry(date: Date())], policy: .never))
    }
}

struct ApolloQuickActionsWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: ApolloQuickActionsEntry

    private let searchURL = URL(string: "apollo://reborn/search")!
    private let actions: [ApolloQuickAction] = [
        ApolloQuickAction(title: "Home", systemImage: "house.fill",
                          tint: Color(red: 0.27, green: 0.42, blue: 0.96),
                          url: URL(string: "apollo://reborn/home")!),
        ApolloQuickAction(title: "Popular", systemImage: "flame.fill",
                          tint: Color(red: 0.98, green: 0.45, blue: 0.20),
                          url: URL(string: "apollo://reddit.com/r/popular")!),
        ApolloQuickAction(title: "All", systemImage: "square.stack.3d.up.fill",
                          tint: Color(red: 0.60, green: 0.40, blue: 0.95),
                          url: URL(string: "apollo://reddit.com/r/all")!),
        ApolloQuickAction(title: "Inbox", systemImage: "tray.fill",
                          tint: Color(red: 0.20, green: 0.70, blue: 0.50),
                          url: URL(string: "apollo://reborn/inbox")!),
    ]

    var body: some View {
        VStack(spacing: 11) {
            // Search pill, branded with the Apollo avatar like the app's own
            // search field. Tapping anywhere opens Apollo's search.
            Link(destination: searchURL) {
                HStack(spacing: 11) {
                    apolloAvatar(size: 30)
                    Text("Search Apollo")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.leading, 11)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(palette.controlBackground, in: Capsule())
            }

            HStack(spacing: 10) {
                ForEach(actions) { action in
                    Link(destination: action.url) {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle().fill(action.tint.opacity(colorScheme == .dark ? 0.22 : 0.15))
                                Image(systemName: action.systemImage)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(action.tint)
                            }
                            .frame(width: 34, height: 34)
                            Text(action.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.controlBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
        .containerBackground(for: .widget) { palette.background }
    }

    /// The Apollo mascot, bundled from the app's own icon asset, clipped to a
    /// circle with a hairline ring so it reads as an avatar.
    private func apolloAvatar(size: CGFloat) -> some View {
        Image("ApolloAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    private var palette: ApolloQuickActionsPalette {
        ApolloQuickActionsPalette(scheme: colorScheme)
    }
}

private struct ApolloQuickAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    let url: URL
}

private struct ApolloQuickActionsPalette {
    let background: Color
    let controlBackground: Color
    let primaryText: Color
    let secondaryText: Color

    init(scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 0.07, green: 0.08, blue: 0.09)
            controlBackground = Color.white.opacity(0.09)
            primaryText = Color.white.opacity(0.95)
            secondaryText = Color.white.opacity(0.55)
        } else {
            background = Color(red: 0.96, green: 0.96, blue: 0.97)
            controlBackground = Color.white
            primaryText = Color.black.opacity(0.85)
            secondaryText = Color.black.opacity(0.45)
        }
    }
}
