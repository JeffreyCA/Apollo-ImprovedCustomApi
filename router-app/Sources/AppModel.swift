import SwiftUI
import UIKit

/// Shown when a routed open fails (target app not installed) or when the user
/// should choose what to do with a link. Keeping the web URL around means the
/// app is always useful on its own — a reviewer (or user) without the target
/// app installed still lands somewhere sensible. (App Review guideline
/// 4.2.3(i): the app must work without requiring another app.)
struct PendingLink: Identifiable {
    let id = UUID()
    let webURL: URL
    let routeName: String?
    let failedTarget: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var routes: [Route] {
        didSet { persistRoutes() }
    }
    @Published var pendingLink: PendingLink?
    @Published var recentLinks: [String] {
        didSet { UserDefaults.standard.set(recentLinks, forKey: Self.recentsKey) }
    }

    private static let routesKey = "routes.v1"
    private static let recentsKey = "recents.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.routesKey),
           let saved = try? JSONDecoder().decode([Route].self, from: data) {
            routes = saved
        } else {
            routes = Route.defaults
        }
        recentLinks = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Entry point for every link: Universal Links (the bounce domain),
    /// links pasted into the in-app tool, and recents re-taps.
    func handle(incoming url: URL) {
        let webURL = RouteEngine.canonicalize(url)
        remember(webURL)

        guard let route = RouteEngine.route(for: webURL, in: routes),
              let target = route.target(for: webURL) else {
            // No rule for this host — let the user decide rather than dead-ending.
            pendingLink = PendingLink(webURL: webURL, routeName: nil, failedTarget: nil)
            return
        }

        UIApplication.shared.open(target, options: [:]) { [weak self] success in
            guard !success else { return }
            // Target app missing: fall back to a chooser with the web URL.
            self?.pendingLink = PendingLink(webURL: webURL, routeName: route.name, failedTarget: target)
        }
    }

    func openInBrowser(_ url: URL) {
        UIApplication.shared.open(url)
    }

    func resetRoutesToDefaults() {
        routes = Route.defaults
    }

    private func remember(_ url: URL) {
        var recents = recentLinks.filter { $0 != url.absoluteString }
        recents.insert(url.absoluteString, at: 0)
        recentLinks = Array(recents.prefix(20))
    }

    private func persistRoutes() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: Self.routesKey)
        }
    }
}
