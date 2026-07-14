import SwiftUI
import WidgetKit

/// Calendar widget: a single locked photo-of-the-day with the date overlaid in
/// one of several styles. Tapping opens the source post in Apollo.
struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    // True in StandBy Night Mode (dark room) and Always-On. Dim the photo so the
    // date reads as a calm nightstand display instead of a red-tinted picture.
    @Environment(\.isLuminanceReduced) private var dimmed
    let entry: WidgetEntry

    var body: some View {
        WidgetShell(entry: entry) {
            imageBackground(entry, fallback: BlueGradient())
                .overlay(dimmed ? Color.black.opacity(0.55) : Color.clear)
        } content: { renders in
            let post = renders[0].post
            ZStack {
                overlay(date: entry.date, style: entry.calendarStyle)
                if entry.calendarShowTitle { titleOverlay(post.title, style: entry.calendarStyle) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(AccentedPhotoBackground(data: renders[0].imageData))
            .opensInApollo(post)
        }
    }

    // MARK: scale

    private var small: Bool { family == .systemSmall }
    private func s(_ base: CGFloat) -> CGFloat { small ? base * 0.72 : base }

    // MARK: date strings

    private func text(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = format
        return f.string(from: date)
    }
    private func weekday(_ d: Date, short: Bool) -> String { text(d, short ? "EEE" : "EEEE") }
    private func dayNum(_ d: Date) -> String { text(d, "d") }
    private func dayPadded(_ d: Date) -> String { text(d, "dd") }
    private func month(_ d: Date, short: Bool) -> String { text(d, short ? "MMM" : "MMMM") }
    private func year(_ d: Date) -> String { text(d, "yyyy") }
    private func isoDate(_ d: Date) -> String { "\(year(d)).\(text(d, "MM")).\(text(d, "dd"))" }

    // MARK: overlays — each is a distinct system-font treatment

    @ViewBuilder private func overlay(date: Date, style: CalendarStyle) -> some View {
        switch style {
        case .rounded:   roundedStyle(date)
        case .serif:     serifStyle(date)
        case .mono:      monoStyle(date)
        case .condensed: condensedStyle(date)
        case .stamp:     stampStyle(date)
        }
    }

    /// SF Pro Rounded — friendly, oversized day number, bottom-left.
    private func roundedStyle(_ d: Date) -> some View {
        VStack(alignment: .leading, spacing: s(-4)) {
            Text(weekday(d, short: false))
                .font(.system(size: s(15), weight: .semibold, design: .rounded))
            Text(dayNum(d))
                .font(.system(size: s(80), weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Text("\(month(d, short: false)) \(year(d))")
                .font(.system(size: s(14), weight: .medium, design: .rounded))
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .modifier(TextShadow())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(s(15))
        .background(alignment: .bottom) { bottomScrim }
    }

    /// New York serif — editorial masthead, centered with a hairline rule.
    /// No dim layer: a full-frame overlay only covers the margin-inset content
    /// rect, so it rendered as a visible floating box over the photo. The text
    /// shadow alone carries legibility (like the other centered style, Stamp).
    private func serifStyle(_ d: Date) -> some View {
        VStack(spacing: s(4)) {
            Text(weekday(d, short: false).uppercased())
                .font(.system(size: s(13), weight: .semibold, design: .serif)).tracking(s(4))
            Text(dayNum(d))
                .font(.system(size: s(88), weight: .bold, design: .serif))
                .lineLimit(1).minimumScaleFactor(0.5)
            Rectangle().fill(.white.opacity(0.85)).frame(width: s(42), height: 1)
            Text("\(month(d, short: false)) \(year(d))")
                .font(.system(size: s(14), weight: .regular, design: .serif)).italic()
        }
        .foregroundStyle(.white)
        .modifier(TextShadow())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Monospaced — digital readout, top-left, ISO date line.
    private func monoStyle(_ d: Date) -> some View {
        VStack(alignment: .leading, spacing: s(2)) {
            Text(weekday(d, short: true).uppercased())
                .font(.system(size: s(12), weight: .medium, design: .monospaced)).tracking(s(3))
                .opacity(0.85)
            Text(dayPadded(d))
                .font(.system(size: s(60), weight: .bold, design: .monospaced))
            Text(isoDate(d))
                .font(.system(size: s(12), weight: .medium, design: .monospaced)).tracking(s(1))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .modifier(TextShadow())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(s(15))
        .background(alignment: .top) { topScrim }
    }

    /// Condensed heavy — sports-poster numerals, bottom, edge-to-edge.
    private func condensedStyle(_ d: Date) -> some View {
        VStack(alignment: .leading, spacing: s(-8)) {
            Text(weekday(d, short: false).uppercased())
                .font(.system(size: s(20), weight: .heavy)).fontWidth(.condensed).tracking(s(1))
            Text(dayNum(d))
                .font(.system(size: s(106), weight: .black)).fontWidth(.condensed)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(month(d, short: false).uppercased())
                .font(.system(size: s(22), weight: .bold)).fontWidth(.condensed).tracking(s(1))
        }
        .foregroundStyle(.white)
        .modifier(TextShadow())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(s(15))
        .background(alignment: .bottom) { bottomScrim }
    }

    /// Outlined, rotated date-stamp — centered, passport-stamp feel.
    private func stampStyle(_ d: Date) -> some View {
        VStack(spacing: s(1)) {
            Text(month(d, short: true).uppercased())
                .font(.system(size: s(14), weight: .heavy, design: .monospaced)).tracking(s(2))
            Text(dayPadded(d))
                .font(.system(size: s(42), weight: .black, design: .monospaced))
            Text(year(d))
                .font(.system(size: s(12), weight: .semibold, design: .monospaced)).tracking(s(2))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, s(14)).padding(.vertical, s(8))
        .overlay(RoundedRectangle(cornerRadius: s(8)).strokeBorder(.white, lineWidth: s(2)))
        .rotationEffect(.degrees(-6))
        .modifier(TextShadow())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: title

    /// Optional post title, placed at the opposite edge from each style's date
    /// anchor so the two never collide.
    @ViewBuilder private func titleOverlay(_ title: String, style: CalendarStyle) -> some View {
        let bottomAnchored = (style == .rounded || style == .condensed)
        Text(title)
            .font(.system(size: s(12), weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(2).minimumScaleFactor(0.8)
            .modifier(TextShadow())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, s(14)).padding(.vertical, s(10))
            .background(alignment: bottomAnchored ? .top : .bottom) {
                // Bleed well past the content margins (like the date scrims) so
                // the gradient reaches the widget edge instead of stopping at
                // the margin-inset content rect and showing a boxy seam.
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: bottomAnchored ? .bottom : .top,
                               endPoint: bottomAnchored ? .top : .bottom)
                    .padding(-24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: bottomAnchored ? .top : .bottom)
    }

    // MARK: scrims

    private var bottomScrim: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            .padding(-24).allowsHitTesting(false)
    }
    private var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            .padding(-24).allowsHitTesting(false)
    }
}

/// Shared legibility shadow for text laid directly over a photo.
private struct TextShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}
