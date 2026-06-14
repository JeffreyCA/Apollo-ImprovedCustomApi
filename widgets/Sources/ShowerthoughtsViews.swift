import SwiftUI
import WidgetKit
import AppIntents

/// Showerthoughts: a single rotating thought on the blue gradient.
struct ShowerthoughtsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if isAccessoryFamily(family) {
            AccessoryPostView(entry: entry, label: "Showerthoughts", icon: "drop.fill")
        } else {
            homeBody
        }
    }

    private var homeBody: some View {
        WidgetShell(entry: entry) {
            BlueGradient()
        } content: { renders in
            let post = renders[0].post
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(label: "Showerthoughts 🚿",
                             trailing: AnyView(NextButton(rotationKey: entry.rotationKey,
                                                          kind: "ShowerthoughtsWidget")))
                Spacer(minLength: 2)
                Text(post.title)
                    .font(titleFont).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(family == .systemLarge ? 8 : (family == .systemSmall ? 6 : 4))
                Spacer(minLength: 2)
                if family != .systemSmall {
                    Text("u/\(post.author)").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
            }
            .opensInApollo(post)
        }
    }

    private var titleFont: Font {
        switch family {
        case .systemSmall: return .system(size: 15)
        case .systemLarge: return .system(size: 24)
        default: return .system(size: 18)
        }
    }
}

/// Jokes: r/Jokes — title is the setup, selftext is the punchline.
struct JokesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    var body: some View {
        if isAccessoryFamily(family) {
            // Lock Screen shows the setup (title); tap opens Apollo for the punchline.
            AccessoryPostView(entry: entry, label: "Jokes", icon: "face.smiling")
        } else {
            homeBody
        }
    }

    private var homeBody: some View {
        WidgetShell(entry: entry) {
            PurpleGradient()
        } content: { renders in
            let post = renders[0].post
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(label: "Jokes 😄",
                             tint: Color(red: 1.0, green: 0.82, blue: 0.35),
                             trailing: AnyView(NextButton(rotationKey: entry.rotationKey,
                                                          kind: "JokesWidget")))
                Spacer(minLength: 2)
                Text(post.title)
                    .font(setupFont).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(family == .systemSmall ? 3 : 4)
                if !post.selftext.isEmpty {
                    Text(post.selftext)
                        .font(punchlineFont)
                        .foregroundStyle(.white.opacity(0.95))
                        .minimumScaleFactor(0.7)
                        .lineLimit(family == .systemLarge ? 8 : (family == .systemSmall ? 3 : 4))
                }
                Spacer(minLength: 2)
            }
            .opensInApollo(post)
        }
    }

    private var setupFont: Font { family == .systemLarge ? .system(size: 20) : .system(size: 15) }
    private var punchlineFont: Font { family == .systemLarge ? .system(size: 22, weight: .bold) : .system(size: 16, weight: .bold) }
}
