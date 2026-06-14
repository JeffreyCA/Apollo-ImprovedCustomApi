import Foundation
import WidgetKit

/// Credentials the widget needs to talk to Reddit, bundled into a single
/// copy/paste "setup code" that the Apollo Reborn tweak generates in
/// Settings → Apollo Reborn → "Copy Widget Setup Code".
///
/// Channel rationale: a widget extension and the host app live in separate
/// sandboxes. Sharing data normally needs an App Group / shared keychain
/// entitlement, which third-party sideload signers (Feather/AltStore/…) can't
/// reliably claim for `group.com.christianselig.apollo`. A one-time manual
/// paste sidesteps that entirely and works identically on every signer.
///
/// Format: base64( JSON { "v": 1, "clientID": "...", "userAgent": "..." } ).
/// `refreshToken` is reserved for a future tier-2 (personal) widget; it is
/// optional and ignored here.
struct SetupCode: Codable {
    var v: Int
    var clientID: String
    var userAgent: String?
    var refreshToken: String?

    /// Decode a pasted code. Accepts either the base64 setup code OR, as a
    /// forgiving fallback, a bare Reddit client_id string (in which case a
    /// generic User-Agent is used).
    static func parse(_ raw: String?) -> SetupCode? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Primary path: base64-encoded JSON.
        if let data = Data(base64Encoded: raw),
           let decoded = try? JSONDecoder().decode(SetupCode.self, from: data),
           !decoded.clientID.isEmpty {
            return decoded
        }

        // Fallback: a raw client_id (Reddit ids are short, no spaces).
        if raw.count >= 8, raw.count <= 40,
           raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return SetupCode(v: 1, clientID: raw, userAgent: nil, refreshToken: nil)
        }

        return nil
    }

    var resolvedUserAgent: String {
        if let ua = userAgent, !ua.isEmpty { return ua }
        return "ApolloRebornWidgets/1.0"
    }

    /// Resolve a widget's setup code, sharing it across all widgets.
    ///
    /// Every Reborn widget lives in the same extension process and so shares
    /// one `UserDefaults`. The first widget you paste a valid code into stashes
    /// it; any other widget whose own field is blank falls back to that stash.
    /// Net effect: paste the code once into ANY widget and the rest pick it up
    /// on their next refresh — no per-widget pasting, no App Group needed.
    static func resolve(_ raw: String?) -> SetupCode? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let parsed = parse(trimmed) {
            SharedSetup.store(trimmed)          // remember for the other widgets
            return parsed
        }
        if let shared = SharedSetup.load() {    // fall back to the shared stash
            return parse(shared)
        }
        return nil
    }
}

/// Cross-widget stash for the setup code (shared `UserDefaults` within the
/// single widget extension; not an App Group).
enum SharedSetup {
    private static let defaults = UserDefaults.standard
    private static let key = "rw.sharedSetupCode"

    static func store(_ code: String) {
        // Only act on a genuine change, then immediately reload every widget so
        // the others re-resolve against this freshly-shared code instead of
        // waiting for their own next WidgetKit budget window.
        guard defaults.string(forKey: key) != code else { return }
        defaults.set(code, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
    static func load() -> String? {
        let v = defaults.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }
}
