import SwiftUI

@main
struct LinkHopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // Universal Links (the bounce domain) arrive as a browsing
                // NSUserActivity. This is the silent, no-dialog path from
                // Safari: reddit.com page → extension redirects to
                // open.apolloreborn.app → iOS launches us here → we bounce
                // app-to-app into apollo:// (also dialog-free).
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        model.handle(incoming: url)
                    }
                }
                // Custom-scheme opens (e.g. Shortcuts automation), if a
                // CFBundleURLTypes scheme is added later.
                .onOpenURL { url in
                    model.handle(incoming: url)
                }
        }
    }
}
