import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var linkText: String = ""

    var body: some View {
        NavigationView {
            List {
                openLinkSection
                rulesSection
                if !model.recentLinks.isEmpty {
                    recentsSection
                }
            }
            .navigationTitle("LinkHop")
        }
        .navigationViewStyle(.stack)
        // Fallback chooser: shown when no rule matched or the target app
        // isn't installed. Always offers the plain web URL, so the app is
        // fully usable with nothing else installed.
        .sheet(item: $model.pendingLink) { pending in
            FallbackSheet(pending: pending)
        }
    }

    private var openLinkSection: some View {
        Section {
            TextField("Paste a link…", text: $linkText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button {
                if let paste = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap(URL.init(string:)) {
                    linkText = paste.absoluteString
                }
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }
            Button {
                guard let url = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                model.handle(incoming: url)
            } label: {
                Label("Open in App", systemImage: "arrow.up.forward.app")
            }
            .disabled(URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines))?.host == nil)
        } header: {
            Text("Open a Link")
        } footer: {
            Text("Links are rewritten to the matching app's URL scheme and opened directly.")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach($model.routes) { $route in
                Toggle(isOn: $route.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name)
                        Text(route.hostSuffixes.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Button("Reset to Defaults", role: .destructive) {
                model.resetRoutesToDefaults()
            }
        } header: {
            Text("Routing Rules")
        } footer: {
            Text("When a link's site matches an enabled rule, it opens in that app instead of the browser.")
        }
    }

    private var recentsSection: some View {
        Section("Recent") {
            ForEach(model.recentLinks, id: \.self) { link in
                Button {
                    if let url = URL(string: link) {
                        model.handle(incoming: url)
                    }
                } label: {
                    Text(link)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct FallbackSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: PendingLink

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(pending.webURL.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                } header: {
                    if let name = pending.routeName {
                        Text("\(name) doesn't appear to be installed")
                    } else {
                        Text("No routing rule matches this link")
                    }
                }
                Section {
                    Button {
                        model.openInBrowser(pending.webURL)
                        dismiss()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    Button {
                        UIPasteboard.general.url = pending.webURL
                        dismiss()
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
            }
            .navigationTitle("Open Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
