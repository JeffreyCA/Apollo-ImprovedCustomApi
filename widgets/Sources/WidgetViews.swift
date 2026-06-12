import SwiftUI
import WidgetKit
import UIKit
import AppIntents

/// Shared shell: routes the entry state to content vs. message, and paints the
/// container background. Non-content states are color-coded (orange=loading,
/// red=needsSetup, purple=error) so issues are obvious at a glance; content
/// uses each widget's own background.
struct WidgetShell<Content: View, Background: View>: View {
    let entry: WidgetEntry
    @ViewBuilder var background: () -> Background
    @ViewBuilder var content: ([RenderPost]) -> Content

    var body: some View {
        routed
            .containerBackground(for: .widget) { backgroundColor }
    }

    @ViewBuilder private var routed: some View {
        switch entry.state {
        case .posts(let renders) where !renders.isEmpty:
            content(renders)
        case .posts:
            // Reached Reddit, but nothing eligible came back.
            MessageView(icon: "tray", title: "Nothing here",
                        detail: "No posts to show right now. Try a different subreddit or sort.")
        case .loading:
            MessageView(icon: "ellipsis", title: "Apollo", detail: "Loading…")
        case .needsSetup:
            SetupView()
        case .error(let msg):
            // Transient (offline / rate-limited) — phrased as "will retry".
            MessageView(icon: "wifi.exclamationmark", title: "Can't reach Reddit", detail: msg)
        }
    }

    // Non-content states use the same on-brand blue gradient as real content, so
    // a not-yet-set-up or offline widget looks intentional — not a crash.
    @ViewBuilder private var backgroundColor: some View {
        switch entry.state {
        case .posts(let r) where !r.isEmpty: background()
        default: BlueGradient()
        }
    }
}

struct MessageView: View {
    @Environment(\.widgetFamily) private var family
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).fontWeight(.bold)
            }
            .font(.caption)
            .foregroundStyle(.white)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .minimumScaleFactor(0.8)
                .lineLimit(family == .systemSmall ? 4 : 6)
            Spacer(minLength: 0)
        }
    }
}

/// First-run / setup state, fronted by the Apollo mascot so it feels like an
/// intentional welcome rather than an error.
struct SetupView: View {
    @Environment(\.widgetFamily) private var family
    private var small: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 7 : 9) {
            Image("ApolloAvatar")
                .accentedPhotoResizable().scaledToFill()
                .frame(width: small ? 38 : 46, height: small ? 38 : 46)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up Apollo widgets")
                    .font(.system(size: small ? 14 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                Text(small
                     ? "Tap Edit and paste your Apollo setup code."
                     : "Tap Edit and paste your setup code from Apollo → Settings → Apollo Reborn. Just once — every widget shares it.")
                    .font(.system(size: small ? 11 : 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .minimumScaleFactor(0.8)
                    .lineLimit(small ? 3 : 5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable bits

/// Small header: a bold tinted title (Apollo uses an emoji, e.g. "Showerthoughts
/// 🚿"), with an optional leading SF Symbol and trailing interactive button.
struct WidgetHeader: View {
    var icon: String? = nil
    let label: String
    var tint: Color = .white
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(label).font(.system(size: 13, weight: .heavy, design: .rounded))
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .foregroundStyle(tint)
    }
}

/// "Show another" button bound to a widget's rotation key. Renders nothing if
/// the key is absent. `kind` is the widget kind to reload explicitly.
struct NextButton: View {
    let rotationKey: String?
    var kind: String? = nil
    var body: some View {
        if let key = rotationKey {
            Button(intent: NextItemIntent(key: key, kind: kind)) {
                Image(systemName: "arrow.clockwise").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Circular ↻ button overlaid on image widgets (Single Post, Photo).
struct NextOverlayButton: View {
    let rotationKey: String?
    var kind: String? = nil
    var body: some View {
        if let key = rotationKey {
            Button(intent: NextItemIntent(key: key, kind: kind)) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Refresh (re-fetch) button for the Feed widget kind.
struct ReloadButton: View {
    let kind: String
    var body: some View {
        Button(intent: ReloadKindIntent(kind: kind)) {
            Image(systemName: "arrow.clockwise").font(.caption2.weight(.bold))
        }
        .buttonStyle(.plain)
    }
}

/// Apollo-style stat line, e.g. "r/Politics ↑57K 💬2K". Density follows the
/// Post widget's DisplayMode: Clean = subreddit only, Standard = + score +
/// comments, Detailed = + age + author.
struct StatsLine: View {
    let post: RedditPost
    var display: DisplayMode = .standard
    var showSubreddit: Bool = true
    var showComments: Bool = true
    var foreground: Color = .white.opacity(0.9)
    var font: Font = .caption2
    var body: some View {
        HStack(spacing: 6) {
            if showSubreddit, !post.subreddit.isEmpty {
                Text("r/\(post.subreddit)").fontWeight(.semibold)
            }
            if display != .clean {
                Label("\(post.score.abbreviated)", systemImage: "arrow.up")
                if showComments {
                    Label("\(post.numComments.abbreviated)", systemImage: "bubble.right")
                }
            }
            if display == .detailed {
                if let age = post.ageString {
                    Label(age, systemImage: "clock")
                }
                if !post.author.isEmpty {
                    Text("u/\(post.author)").lineLimit(1)
                }
            }
        }
        .font(font)
        .foregroundStyle(foreground)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .monospacedDigit()   // stops scores/comments from jittering on rotation
    }
}

extension Int {
    /// Apollo-style counts: 950 → "950", 1500 → "1.5k", 12400 → "12.4k",
    /// 23000 → "23k", 1_500_000 → "1.5m". Trailing ".0" is dropped.
    var abbreviated: String {
        func trim(_ v: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        if self >= 1_000_000 { return trim(Double(self) / 1_000_000, "m") }
        if self >= 1_000 { return trim(Double(self) / 1_000, "k") }
        return "\(self)"
    }
}

/// The blue gradient used for Showerthoughts (Apollo's signature look).
struct BlueGradient: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.96),
                                Color(red: 0.36, green: 0.36, blue: 0.98)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Indigo/purple gradient used for Jokes.
struct PurpleGradient: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.36, blue: 0.98),
                                Color(red: 0.50, green: 0.30, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// Init from a Reddit hex color like "#0079D3"; nil if blank/invalid.
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

extension View {
    /// Apply a deep link that opens the post in Apollo, if available.
    @ViewBuilder func opensInApollo(_ post: RedditPost) -> some View {
        if let url = post.apolloURL { self.widgetURL(url) } else { self }
    }
}

func imageFromData(_ data: Data?) -> Image? {
    guard let data, let ui = UIImage(data: data) else { return nil }
    return Image(uiImage: ui)
}

extension Image {
    /// `resizable()`, with the system's photo treatment in accented rendering
    /// (iOS 18 tinted and iOS 26 clear/tinted Home Screens): desaturated and
    /// washed with the accent color, matching Apple's own Photos widget.
    /// Without the annotation the system flattens every image into a flat
    /// accent silhouette, which turned photos and thumbnails into blank blobs.
    @ViewBuilder func accentedPhotoResizable() -> some View {
        if #available(iOSApplicationExtension 18.0, iOS 18.0, *) {
            self.resizable().widgetAccentedRenderingMode(.accentedDesaturated)
        } else {
            self.resizable()
        }
    }
}

/// Accented rendering (iOS 18 tinted, iOS 26 clear/tinted) DISCARDS the
/// container background — which is where the full-bleed photos of Photo, Post,
/// and Calendar live — so those widgets rendered as bare scrims/text floating
/// on glass. This modifier re-draws the photo as a full-bleed underlay in the
/// content layer (which accented mode keeps), marked full-color. Inert in
/// normal light/dark rendering, where the container background still shows.
struct AccentedPhotoBackground: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetContentMargins) private var margins
    let data: Data?

    func body(content: Content) -> some View {
        if renderingMode == .accented, let img = imageFromData(data) {
            content.background {
                img.accentedPhotoResizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // Bleed past the default content margins to the widget edge
                    // (the system clips to the container shape).
                    .padding(EdgeInsets(top: -margins.top, leading: -margins.leading,
                                        bottom: -margins.bottom, trailing: -margins.trailing))
            }
        } else {
            content
        }
    }
}

/// First render of a `.posts` entry (for reading its background image).
func firstRender(_ entry: WidgetEntry) -> RenderPost? {
    if case .posts(let r) = entry.state { return r.first }
    return nil
}

/// Shared full-bleed photo background for the image widgets (Photo, Post,
/// Calendar): the downsampled image filled to the frame with a subtle vignette
/// for depth, or a gradient fallback when there's no image.
@ViewBuilder func imageBackground(_ entry: WidgetEntry, fallback: some View) -> some View {
    if let data = firstRender(entry)?.imageData, let img = imageFromData(data) {
        img.resizable().scaledToFill()
            .overlay {
                // Gentle corner vignette so edges don't blow out and the photo
                // reads as art-directed rather than a flat crop.
                RadialGradient(colors: [.clear, .black.opacity(0.22)],
                               center: .center, startRadius: 40, endRadius: 320)
                    .allowsHitTesting(false)
            }
    } else {
        fallback
    }
}

func firstPost(_ entry: WidgetEntry) -> RedditPost? {
    if case .posts(let r) = entry.state { return r.first?.post }
    return nil
}

func isAccessoryFamily(_ family: WidgetFamily) -> Bool {
    switch family {
    case .accessoryRectangular, .accessoryInline, .accessoryCircular: return true
    default: return false
    }
}

/// Short stable name for a widget family, for diagnostic logging.
func familyName(_ family: WidgetFamily) -> String {
    switch family {
    case .systemSmall: return "small"
    case .systemMedium: return "medium"
    case .systemLarge: return "large"
    case .systemExtraLarge: return "xlarge"
    case .accessoryRectangular: return "accRect"
    case .accessoryInline: return "accInline"
    case .accessoryCircular: return "accCircular"
    @unknown default: return "family\(family.rawValue)"
    }
}

/// Lock-screen (accessory) rendering for a text post. Accessory widgets are
/// monochrome/tinted by the system, so no colors/images — just text + a symbol.
/// Tapping opens the post in Apollo.
struct AccessoryPostView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry
    let label: String
    let icon: String

    var body: some View {
        content
            .widgetURL(firstPost(entry)?.apolloURL)
            .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder private var content: some View {
        if let post = firstPost(entry) {
            switch family {
            case .accessoryInline:
                Label(post.title, systemImage: icon).lineLimit(1)
            case .accessoryCircular:
                Image(systemName: icon).font(.title2).widgetAccentable()
            default: // accessoryRectangular
                VStack(alignment: .leading, spacing: 1) {
                    Label(label.uppercased(), systemImage: icon)
                        .font(.system(size: 11, weight: .bold))
                        .widgetAccentable()
                    Text(post.title)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            // No content yet (setup/loading/error) — keep it terse for the lock screen.
            switch family {
            case .accessoryInline: Label(accessoryNote, systemImage: icon).lineLimit(1)
            case .accessoryCircular: Image(systemName: icon).font(.title2)
            default:
                VStack(alignment: .leading) {
                    Label(label.uppercased(), systemImage: icon).font(.system(size: 11, weight: .bold)).widgetAccentable()
                    Text(accessoryNote).font(.system(size: 13)).lineLimit(2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var accessoryNote: String {
        switch entry.state {
        case .needsSetup: return "Set up in Apollo"
        case .error: return "Tap to open Apollo"
        default: return "Loading…"
        }
    }
}
