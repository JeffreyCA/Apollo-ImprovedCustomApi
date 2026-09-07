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
/// Format: base64( JSON { "v", "clientID", "userAgent", … } ).
///   v1  – clientID + userAgent: the app-only tier every widget started with.
///   v2  – adds `refreshToken` + `username` (copied "with account"), which is
///         what Home and the user's own multireddits need, and `clientSecret`
///         for "web app" API keys. Older widget builds ignore the extra keys.
struct SetupCode: Codable {
    var v: Int
    var clientID: String
    var userAgent: String?
    var clientSecret: String?
    var refreshToken: String?
    var username: String?

    var hasAccount: Bool { !(refreshToken ?? "").isEmpty }

    /// Decode a pasted code. Accepts either the base64 setup code OR, as a
    /// forgiving fallback, a bare Reddit client_id string (in which case a
    /// generic User-Agent is used).
    static func parse(_ raw: String?) -> SetupCode? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Primary path: base64-encoded JSON. Every code starts with "eyJ"
        // (base64 of `{"`); a keyboard's auto-capitalization turns a typed one
        // into "EyJ", which is different base64 — undo that one mangling.
        var candidates = [raw]
        if raw.hasPrefix("EyJ") { candidates.append("eyJ" + raw.dropFirst(3)) }
        for candidate in candidates {
            if let data = Data(base64Encoded: candidate),
               let decoded = try? JSONDecoder().decode(SetupCode.self, from: data),
               !decoded.clientID.isEmpty {
                return decoded
            }
        }

        // Fallback: a raw client_id (Reddit ids are short, no spaces).
        if raw.count >= 8, raw.count <= 40,
           raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return SetupCode(v: 1, clientID: raw)
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
    ///
    /// A code copied *with account* outranks a plain one for the same API key:
    /// pasting it into ONE widget upgrades every widget, and the plain codes
    /// still sitting in the other widgets' fields don't downgrade the stash
    /// back. Only the first stash and that upgrade reload every widget —
    /// two widgets holding different codes would otherwise ping-pong
    /// `reloadAllTimelines` at each other (each rebuild re-stashing its own).
    static func resolve(_ raw: String?) -> SetupCode? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shared = SharedSetup.load().flatMap(parse)
        if !trimmed.isEmpty, let own = parse(trimmed) {
            if let shared, shared.hasAccount, !own.hasAccount, shared.clientID == own.clientID {
                return shared
            }
            let upgrade = shared.map { own.hasAccount && !$0.hasAccount } ?? true
            SharedSetup.store(trimmed, reloadOthers: upgrade)   // remember for the other widgets
            return own
        }
        return shared                            // fall back to the shared stash
    }
}

/// Cross-widget stash for the setup code (shared `UserDefaults` within the
/// single widget extension; not an App Group).
enum SharedSetup {
    private static let defaults = UserDefaults.standard
    private static let key = "rw.sharedSetupCode"

    static func store(_ code: String, reloadOthers: Bool) {
        // Only act on a genuine change. `reloadOthers` immediately reloads
        // every widget so the ones with a blank field re-resolve against this
        // freshly-shared code instead of waiting for their own next WidgetKit
        // budget window — the caller limits that to the first stash and an
        // account upgrade so differing codes can't chase each other.
        guard defaults.string(forKey: key) != code else { return }
        defaults.set(code, forKey: key)
        if reloadOthers { WidgetCenter.shared.reloadAllTimelines() }
    }
    static func load() -> String? {
        let v = defaults.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }
}
