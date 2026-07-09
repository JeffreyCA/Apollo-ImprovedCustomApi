//
//  ApolloAppleTranslation.swift
//  Apollo-Reborn
//
//  On-device translation backend powered by Apple's Translation framework
//  (iOS 18.0+). This is the project's first Swift compilation unit; it exists
//  solely because Apple's programmatic translation API has *no* Objective-C
//  surface and is only reachable from Swift/SwiftUI.
//
//  Why a hidden SwiftUI host?
//  --------------------------
//  A `TranslationSession` cannot be constructed directly on iOS 18–25; it is
//  vended ONLY inside the SwiftUI `.translationTask(_:action:)` closure attached
//  to a live view, and it is view-lifecycle-bound. The session that comes from a
//  view is also the only one that can drive Apple's one-time, system-presented
//  language-model *download* sheet.
//
//  Source language is supplied EXPLICITLY by the caller (detected client-side via
//  NLLanguageRecognizer in ApolloTranslation.xm). We deliberately do NOT use
//  `source: nil` auto-detect: when Apple can't auto-detect a snippet it does not
//  throw — it SUSPENDS the translate call and presents a "select a language"
//  picker, which (because we drain requests serially) would block every queued
//  translation behind it. An explicit source avoids the picker entirely.
//
//  We keep one `TranslationSession` per source language (each vended by its own
//  hidden `.translationTask` probe), so a mixed-language thread (e.g. Portuguese +
//  French comments) doesn't thrash a single session's configuration.
//
//  The Objective-C bridge is `ApolloAppleTranslator.translate(_:from:to:completion:)`.
//

import Foundation

#if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
import UIKit
import SwiftUI
import Translation
import os

@available(iOS 18.0, *)
private let appleTranslateLog = Logger(subsystem: "apollofix", category: "AppleTranslate")

// MARK: - Coordinator

/// Owns the hidden SwiftUI probe host and one `TranslationSession` per source
/// language, and funnels Objective-C translation requests into them. Main-actor
/// isolated so every completion is delivered on the main thread (matching the
/// other providers).
@available(iOS 18.0, *)
@MainActor
final class ApolloAppleTranslationCoordinator: ObservableObject {
    static let shared = ApolloAppleTranslationCoordinator()

    struct Job {
        let text: String
        let completion: (String?, NSError?) -> Void
    }

    /// Active source-language codes (lowercased, e.g. "pt", "fr"). Each drives one
    /// hidden `.translationTask` probe via the host view's ForEach. @Published so
    /// adding a source re-renders the host and spins up that source's session.
    @Published private(set) var sources: [String] = []

    private var target: String = "en"
    private var configs: [String: TranslationSession.Configuration] = [:]
    private var streams: [String: AsyncStream<Job>] = [:]
    private var continuations: [String: AsyncStream<Job>.Continuation] = [:]
    private var host: UIViewController?
    // Source languages the user declined to download (dismissed the system download
    // sheet). We never re-prompt for these for the rest of the session, so the prompt
    // can't keep re-popping. (Cleared on app relaunch.)
    private var declinedSources: Set<String> = []

    private init() {}

    // Objective-C entry hops here already on the main actor. `source` and `target`
    // are normalized language codes; source is always non-empty (caller detects it).
    // Build a Locale.Language from a bare code ("pt", "en"). Use languageCode: (not
    // identifier:) so the value canonicalizes identically to what LanguageAvailability
    // checks — identifier: can attach an unintended region and mismatch.
    private func makeLanguage(_ code: String) -> Locale.Language {
        Locale.Language(languageCode: Locale.LanguageCode(code))
    }

    func enqueue(text: String, source: String, target: String,
                 completion: @escaping (String?, NSError?) -> Void) {
        let src = source.lowercased()
        let tgt = target.lowercased()
        guard !src.isEmpty, !tgt.isEmpty else {
            completion(nil, Self.makeError(code: 302, "Missing source/target language"))
            return
        }

        // Target language is fixed per browsing session. If it changes, tear down every
        // source's consumer (configs are target-specific) and start over.
        if tgt != self.target {
            self.target = tgt
            for (_, c) in continuations { c.finish() }
            continuations.removeAll()
            streams.removeAll()
            configs.removeAll()
            sources = []
        }

        // One serial request stream per source language. The CONSUMER is decided once,
        // asynchronously, based on availability (see startConsumer): a headless direct
        // TranslationSession for installed pairs (iOS 26+), or the hosted SwiftUI
        // .translationTask probe for pairs that still need the one-time download.
        if continuations[src] == nil {
            let made = AsyncStream<Job>.makeStream(of: Job.self)
            streams[src] = made.stream
            continuations[src] = made.continuation
            startConsumer(src: src, tgt: tgt)
        }

        continuations[src]?.yield(Job(text: text, completion: completion))
    }

    // Decide and start the consumer for a source's stream. Runs once per source.
    private func startConsumer(src: String, tgt: String) {
        Task { @MainActor in
            #if compiler(>=6.2)
            // Built with the iOS 26 SDK (Xcode 26+ / Swift 6.2+): on iOS 26 use the
            // headless TranslationSession(installedSource:target:) for installed pairs.
            // It's owned/reusable and NOT view-anchored, so it survives the SwiftUI host
            // re-renders that collapse a .translationTask-vended session under load.
            // That initializer is iOS-26-SDK-only, so this whole branch is compiled out on
            // older SDKs (e.g. CI on Xcode 16) and we fall through to the hosted probe.
            if #available(iOS 26.0, *) {
                let s = self.makeLanguage(src)
                let t = self.makeLanguage(tgt)
                let status = await LanguageAvailability().status(from: s, to: t)
                if status == .installed {
                    // Headless, owned, reusable session — NOT view-anchored, so it can't
                    // be poisoned by SwiftUI host re-renders. This is the fix.
                    appleTranslateLog.log("direct session \(src, privacy: .public)->\(tgt, privacy: .public) (installed)")
                    let session = TranslationSession(installedSource: s, target: t)
                    await self.drainDirect(src: src, session: session)
                } else if status == .supported && !self.declinedSources.contains(src) {
                    // Available but not downloaded: prompt-on-detect. The hosted
                    // .translationTask's first translate shows Apple's one-time download
                    // sheet. If the user dismisses it, `run` records the decline so we
                    // never re-prompt for this language (no million-popups).
                    appleTranslateLog.log("hosted session \(src, privacy: .public)->\(tgt, privacy: .public) (needs download)")
                    self.configs[src] = TranslationSession.Configuration(source: s, target: t)
                    self.installHostIfNeeded()
                    self.sources.append(src)
                } else {
                    #if APOLLO_SIM_BUILD
                    // SIMULATOR: the iOS Translation engine does not exist in sim
                    // runtimes (status is .unsupported for every pair), but the
                    // identical engine runs on the host Mac. Route through the
                    // local test bridge (scripts/apple-translate-bridge.swift,
                    // 127.0.0.1:8765) so the Apple provider is fully exercisable
                    // in the sim. Dev-only: compiled out of device builds.
                    appleTranslateLog.log("sim: bridging \(src, privacy: .public)->\(tgt, privacy: .public) to host Apple engine")
                    await self.drainViaHostBridge(src: src, tgt: tgt)
                    #else
                    // .unsupported, or already declined this session -> skip silently.
                    appleTranslateLog.log("skip \(src, privacy: .public)->\(tgt, privacy: .public) (status=\(String(describing: status), privacy: .public), declined=\(self.declinedSources.contains(src)))")
                    await self.drainFail(src: src, message: "\(src) not available")
                    #endif
                }
                return
            }
            #endif
            // iOS 18–25, or built against an SDK without the headless initializer (Xcode
            // < 26): a hosted .translationTask probe drives both translation and the
            // one-time download sheet.
            appleTranslateLog.log("hosted session \(src, privacy: .public)->\(tgt, privacy: .public)")
            self.configs[src] = TranslationSession.Configuration(
                source: self.makeLanguage(src),
                target: self.makeLanguage(tgt)
            )
            self.installHostIfNeeded()
            self.sources.append(src)   // renders the probe -> .translationTask -> run()
        }
    }

    #if compiler(>=6.2)
    // Headless consumer: drains a source's jobs serially through a reused direct session.
    // Only reachable from the iOS-26-SDK headless path above, so it's gated the same way.
    private func drainDirect(src: String, session: TranslationSession) async {
        guard let stream = streams[src] else { return }
        for await job in stream {
            var attempt = 0
            while true {
                do {
                    let response = try await session.translate(job.text)
                    job.completion(response.targetText, nil)
                    break
                } catch is CancellationError {
                    job.completion(nil, Self.makeError(code: 304, "Translation cancelled"))
                    break
                } catch let error as NSError {
                    attempt += 1
                    // The framework intermittently throws TranslationError#1 ("Unable to
                    // Translate") under rapid serial load even for installed pairs. One
                    // short retry recovers most of these; give up after that.
                    if attempt >= 2 {
                        appleTranslateLog.error("direct translate failed (\(src, privacy: .public)) after retry: \(error.domain, privacy: .public)#\(error.code)")
                        job.completion(nil, error)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }
    #endif

    #if APOLLO_SIM_BUILD
    // Simulator-only: drain a source's jobs through the host Mac's Apple
    // translation engine (scripts/apple-translate-bridge.swift). The sim shares
    // the host's loopback, so 127.0.0.1 reaches the Mac directly.
    private func drainViaHostBridge(src: String, tgt: String) async {
        guard let stream = streams[src] else { return }
        for await job in stream {
            do {
                let translated = try await Self.hostBridgeTranslate(text: job.text, source: src, target: tgt)
                job.completion(translated, nil)
            } catch {
                appleTranslateLog.error("sim bridge failed (\(src, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                job.completion(nil, Self.makeError(code: 305,
                    "Apple sim bridge: \(error.localizedDescription). Run scripts/apple-bridge.sh on the Mac."))
            }
        }
    }

    private static func hostBridgeTranslate(text: String, source: String, target: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["q": text, "source": source, "target": target])
        let (data, response) = try await URLSession.shared.data(for: request)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let translated = obj?["translatedText"] as? String, !translated.isEmpty else {
            throw makeError(code: 306, (obj?["error"] as? String) ?? "bridge returned no translation")
        }
        return translated
    }
    #endif

    // Fail every job for an unsupported source (so callers don't hang).
    private func drainFail(src: String, message: String) async {
        guard let stream = streams[src] else { return }
        for await job in stream {
            job.completion(nil, Self.makeError(code: 303, message))
        }
    }

    /// Stable Configuration instance for a source (so SwiftUI's `.translationTask`
    /// doesn't restart on every re-render).
    func configuration(for source: String) -> TranslationSession.Configuration? {
        configs[source]
    }

    /// Hosted consumer for a not-yet-downloaded language. We require the language to be
    /// detected on at least TWO DISTINCT texts before showing Apple's download sheet —
    /// a one-off snippet misdetected as e.g. Indonesian (when the sub is really Italian)
    /// never corroborates, so it never prompts; the sub's real language does so instantly.
    /// Once we prompt, the first translate suspends for the system sheet: if it succeeds
    /// (downloaded) the rest stream through; if it fails (user dismissed it) we record the
    /// decline and stop, so the prompt never re-pops for this language this session.
    func run(source: String, session: TranslationSession) async {
        guard let stream = streams[source] else { return }
        var declined = false
        var seenTexts = Set<Int>()
        for await job in stream {
            if declined { job.completion(nil, Self.makeError(code: 305, "\(source) download declined")); continue }
            seenTexts.insert(job.text.hashValue)
            if seenTexts.count < 2 {
                // Only one distinct snippet so far — likely a one-off misdetection. Don't
                // prompt to download yet; wait for a second distinct text to corroborate.
                job.completion(nil, Self.makeError(code: 306, "\(source) awaiting corroboration"))
                continue
            }
            do {
                let response = try await session.translate(job.text)
                job.completion(response.targetText, nil)
            } catch {
                // Dismissed download sheet (or failure) -> don't keep prompting.
                declined = true
                declinedSources.insert(source)
                appleTranslateLog.log("download declined/failed for \(source, privacy: .public); won't re-prompt this session")
                job.completion(nil, error as NSError)
            }
        }
    }

    // MARK: Hidden host

    private func installHostIfNeeded() {
        guard host == nil else { return }
        guard let window = Self.activeWindow(), let root = window.rootViewController else {
            appleTranslateLog.error("no key window/root VC yet; deferring Apple translation host")
            return
        }
        var parent = root
        while let presented = parent.presentedViewController, !presented.isBeingDismissed {
            parent = presented
        }

        let hosting = UIHostingController(rootView: ApolloTranslationProbeHost(coordinator: self))
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        hosting.view.alpha = 0.001
        hosting.view.isUserInteractionEnabled = false
        hosting.view.backgroundColor = .clear

        parent.addChild(hosting)
        parent.view.addSubview(hosting.view)
        hosting.didMove(toParent: parent)

        host = hosting
        appleTranslateLog.log("installed hidden Apple translation host")
    }

    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first
    }

    private static func makeError(code: Int, _ message: String) -> NSError {
        NSError(domain: "ApolloAppleTranslation", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Hidden probe host

/// A 1×1, effectively invisible host carrying one `.translationTask` per active
/// source language. Each task vends a `TranslationSession` for that source.
@available(iOS 18.0, *)
private struct ApolloTranslationProbeHost: View {
    @ObservedObject var coordinator: ApolloAppleTranslationCoordinator

    var body: some View {
        ZStack {
            ForEach(coordinator.sources, id: \.self) { src in
                if let cfg = coordinator.configuration(for: src) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .translationTask(cfg) { session in
                            await coordinator.run(source: src, session: session)
                        }
                }
            }
        }
        .frame(width: 1, height: 1)
    }
}

#endif

// MARK: - Objective-C bridge

/// Stable, always-present Objective-C entry point. Defined unconditionally (no
/// `@available` on the class) so the generated `ApolloReborn-Swift.h` always
/// declares it; the iOS-18 gate lives inside.
@objc(ApolloAppleTranslator)
public final class ApolloAppleTranslator: NSObject {

    /// `source` and `target` are normalized language codes (e.g. "pt", "en").
    /// `completion` is always invoked on the main thread.
    @objc public static func translate(_ text: String,
                                       from source: String,
                                       to target: String,
                                       completion: @escaping (String?, NSError?) -> Void) {
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 18.0, *) {
            Task { @MainActor in
                ApolloAppleTranslationCoordinator.shared.enqueue(text: text, source: source, target: target, completion: completion)
            }
            return
        }
        #endif
        completion(nil, NSError(domain: "ApolloAppleTranslation", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Apple translation requires iOS 18 or later"]))
    }

    /// Whether the on-device Apple translation backend can run on this OS (iOS 18+).
    @objc public static func isSupported() -> Bool {
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    // MARK: - Supported languages (for the Target Language picker)
    //
    // Apple Translation only covers ~20 languages (far fewer than Google), so when
    // Apple is the selected provider the settings picker should offer only those.
    // `supportedLanguages` is async, so we cache the base codes — both in memory and
    // (across launches) in UserDefaults — and expose a synchronous accessor the
    // Objective-C picker reads. `warmSupportedLanguages()` kicks off the refresh.

    // Serial queue (not NSLock) so the cache can be touched from the async warm
    // Task without tripping Swift's "lock unavailable from async contexts" rule.
    private static let supportedCodesQueue = DispatchQueue(label: "apollofix.appleTranslate.supportedCodes")
    private static var cachedSupportedCodesStorage: [String] = []
    private static var supportedWarmStarted = false
    private static let supportedCodesDefaultsKey = "ApolloAppleSupportedLangCodes"

    /// Lowercase ISO base codes Apple can translate (e.g. "en", "pt", "ja").
    /// Empty until the first warm completes; seeded instantly from the persisted
    /// cache on subsequent launches.
    @objc public static func supportedLanguageCodes() -> [String] {
        return supportedCodesQueue.sync { cachedSupportedCodesStorage }
    }

    /// Kicks off (once per launch) an async query of Apple's supported languages and
    /// caches the base codes. Cheap to call repeatedly; safe from the main thread.
    @objc public static func warmSupportedLanguages() {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            let shouldStart: Bool = supportedCodesQueue.sync {
                let alreadyStarted = supportedWarmStarted
                supportedWarmStarted = true
                if cachedSupportedCodesStorage.isEmpty,
                   let persisted = UserDefaults.standard.array(forKey: supportedCodesDefaultsKey) as? [String] {
                    cachedSupportedCodesStorage = persisted
                }
                return !alreadyStarted
            }
            guard shouldStart else { return }

            Task.detached(priority: .utility) {
                let langs = await LanguageAvailability().supportedLanguages
                var set = Set<String>()
                for lang in langs {
                    if let code = lang.languageCode?.identifier.lowercased(), !code.isEmpty {
                        set.insert(code)
                    }
                }
                let codes = Array(set).sorted()
                guard !codes.isEmpty else { return }
                supportedCodesQueue.sync { cachedSupportedCodesStorage = codes }
                UserDefaults.standard.set(codes, forKey: supportedCodesDefaultsKey)
            }
        }
        #endif
    }
}
