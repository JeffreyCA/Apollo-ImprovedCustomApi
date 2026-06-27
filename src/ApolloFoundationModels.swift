//
//  ApolloFoundationModels.swift
//  Apollo-Reborn
//
//  Swift -> ObjC bridge to Apple's on-device FoundationModels framework
//  (iOS 26+). The rest of the tweak is pure Objective-C/Logos and cannot call
//  the Swift-only `LanguageModelSession` / `SystemLanguageModel` API directly,
//  nor `async` functions, so this file exposes a small `@objc` surface with
//  completion-block callbacks that the ObjC feature module (ApolloAISummary.xm)
//  drives.
//
//  The whole framework is weak-linked (see Makefile `-weak_framework
//  FoundationModels`) and every entry point is guarded by `#available(iOS 26)`,
//  so the tweak still loads on older OSes — it simply reports "unavailable".
//

import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// Matches ApolloLog's os_log subsystem ("apollofix") so these diagnostics land
// in the same stream the rest of the tweak (and run-in-sim.sh) reads. Plain
// NSLog is wrong here: on iOS 26 it redacts every `%@` argument to <private>
// (the same reason ApolloCommon switched to os_log), so the identifiers and
// timings below would have been unreadable. These are dev diagnostics, so they
// log at `.debug` (not persisted in release unless debug logging is enabled).
private let aiLog = Logger(subsystem: "apollofix", category: "AISummary")

#if canImport(FoundationModels)
// Guided-generation schema for Theme Builder. Declaring the output with
// `@Generable` forces the on-device model to fill a structurally valid palette
// instead of emitting free-form JSON we then regex-parse, and the per-field
// `@Guide` hints keep each role on-purpose. This is the core fix for the model
// wandering off-palette (e.g. a "Superman" request drifting to green/orange):
// the shape is now schema-guaranteed and each color's intent is described. The
// ObjC side (ApolloThemeAI.m) still owns contrast repair, validation, and
// saving — we serialize this back into the exact JSON shape it already parses,
// so nothing downstream changes.
@available(iOS 26.0, *)
@Generable
struct ApolloGeneratedPalette {
    @Guide(description: "Accent as #RRGGBB. The vivid signature color that carries the theme's personality — links, the selected tab, buttons.")
    var accent: String
    @Guide(description: "Main content background as #RRGGBB. A calm, lower-saturation large surface that text sits on.")
    var background: String
    @Guide(description: "Secondary/grouped background as #RRGGBB. Slightly distinct from the main background.")
    var secondaryBackground: String
    @Guide(description: "Tertiary/dimmed background as #RRGGBB. Distinct again from the secondary background.")
    var tertiaryBackground: String
    @Guide(description: "Separator/hairline color as #RRGGBB. Subtle but visible against the backgrounds.")
    var separators: String
    @Guide(description: "Navigation and tab bar background as #RRGGBB.")
    var barsAndChrome: String
    @Guide(description: "Secondary text as #RRGGBB — usernames, timestamps, counts. Readable, not faint.")
    var secondaryText: String
    @Guide(description: "Primary text as #RRGGBB. Must be clearly readable on every background above.")
    var text: String
}

@available(iOS 26.0, *)
@Generable
struct ApolloGeneratedTweak {
    @Guide(description: "Short button title for a one-tap refinement, e.g. \"Make darker\".")
    var title: String
    @Guide(description: "One-sentence instruction describing the refinement to apply.")
    var instruction: String
}

@available(iOS 26.0, *)
@Generable
struct ApolloGeneratedTheme {
    @Guide(description: "Short, original theme name (max 32 characters). Never reuse a trademarked or official name.")
    var name: String
    @Guide(description: "One concise sentence describing the look.")
    var shortDescription: String
    @Guide(description: "Three to five short aesthetic tags.")
    var aestheticTags: [String]
    @Guide(description: "The light mode palette.")
    var lightMode: ApolloGeneratedPalette
    @Guide(description: "The dark mode palette.")
    var darkMode: ApolloGeneratedPalette
    @Guide(description: "Up to three short readability notes.")
    var accessibilityNotes: [String]
    @Guide(description: "Two suggested one-tap refinements the user could apply next.")
    var suggestedTweaks: [ApolloGeneratedTweak]
}
#endif

@objc(ApolloFoundationModels)
public final class ApolloFoundationModels: NSObject {

    @objc public static let shared = ApolloFoundationModels()

    /// Prepared, short-lived sessions keyed by the post/type that will consume
    /// them. Prewarming the actual instructed session avoids paying session
    /// setup and guardrail preparation again when generation starts.
    private var preparedSessions: [String: Any] = [:]
    private var preparedInstructions: [String: String] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// The on-device model used for every summary. We deliberately do NOT use
    /// `SystemLanguageModel.default`: its default safety guardrail frequently
    /// false-positives on ordinary news / political Reddit threads, throwing
    /// `guardrailViolation` ("Detected content likely to be unsafe") and refusing
    /// to summarize them — the single most common failure users hit.
    /// `.permissiveContentTransformations` is Apple's sanctioned guardrail set for
    /// content-transformation use cases (summarizing / rewriting text the user is
    /// already reading), which is exactly what AI Summaries does. Genuinely unsafe
    /// content can still trip it; that surfaces as our usual code-7 error. Stored
    /// untyped (`Any?`) so the property needs no availability annotation; built
    /// lazily on first use under an `#available` check. Built once and reused so we
    /// don't re-prepare guardrail assets per session.
    private static var cachedModel: Any?

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func summarizationModel() -> SystemLanguageModel {
        if let model = cachedModel as? SystemLanguageModel { return model }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        cachedModel = model
        return model
    }
    #endif

    /// Mirrors `SystemLanguageModel.Availability`, flattened to an Int so ObjC
    /// can branch without bridging the Swift enum.
    ///   0 = available
    ///   1 = appleIntelligenceNotEnabled  (user hasn't turned on Apple Intelligence)
    ///   2 = modelNotReady                (assets still downloading)
    ///   3 = deviceNotEligible            (hardware can't run it)
    ///   4 = osTooOld                     (< iOS 26, framework absent)
    ///   5 = unknown
    @objc public func availabilityStatus() -> Int {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return 0
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return 1
                case .modelNotReady:               return 2
                case .deviceNotEligible:           return 3
                @unknown default:                  return 5
                }
            @unknown default:
                return 5
            }
        }
        #endif
        return 4
    }

    /// Convenience for ObjC: is the on-device model ready to generate right now?
    @objc public func isModelAvailable() -> Bool {
        return availabilityStatus() == 0
    }

    /// Prepare the exact instructed session that a subsequent summarize call
    /// will use. Sessions are consumed once and discarded so unrelated Reddit
    /// threads never accumulate transcript context.
    @objc public func prepareSession(_ identifier: String, instructions: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard !identifier.isEmpty else { return }
            // Keep an already-prewarmed session only if it was staged under the
            // SAME instructions. A post box prewarmed with the Post prompt can
            // later be asked to summarize post+article under the Both prompt
            // (they share one request id), so re-prepare when the instructions
            // differ instead of silently reusing the stale prompt.
            if preparedSessions[identifier] != nil,
               preparedInstructions[identifier] == instructions {
                return
            }
            let session = LanguageModelSession(model: Self.summarizationModel(), instructions: instructions)
            preparedSessions[identifier] = session
            preparedInstructions[identifier] = instructions
            session.prewarm()
        }
        #endif
    }

    @objc public func discardPreparedSession(_ identifier: String) {
        preparedSessions.removeValue(forKey: identifier)
        preparedInstructions.removeValue(forKey: identifier)
    }

    @objc public func cancelRequest(_ identifier: String) {
        preparedSessions.removeValue(forKey: identifier)
        preparedInstructions.removeValue(forKey: identifier)
        activeTasks.removeValue(forKey: identifier)?.cancel()
    }

    /// Summarize `text` using `instructions` as the system prompt. `onPartial`
    /// fires repeatedly with the cumulative text as it streams; `onComplete`
    /// fires once with the final text (or an error). Both callbacks are invoked
    /// on the main thread, so the ObjC side can touch UIKit directly.
    @objc public func summarize(_ text: String,
                                identifier: String,
                                instructions: String,
                                maximumResponseTokens: Int,
                                onPartial: @escaping (String) -> Void,
                                onComplete: @escaping (String?, NSError?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            onComplete(nil, Self.makeError(code: 4, message: "Requires iOS 26 or later"))
            return
        }

        // NOTE: we intentionally do NOT pre-gate on `availabilityStatus() == 0`.
        // On iOS 27, `SystemLanguageModel.default.availability` reports
        // `.appleIntelligenceNotEnabled` to sideloaded apps even when the model
        // works (other clients like Hydra summarize fine on the same device).
        // So we just attempt generation and let an actual thrown error from the
        // session be the only thing that stops us. `availabilityStatus()` remains
        // for diagnostics/UI only.

        // Run the async generation on the main actor: the framework does the
        // heavy work on its own executor and only resumes here to deliver
        // snapshots, so the callbacks land on the main thread for free.
        let task = Task { @MainActor in
            // A fresh, permissive-guardrail session built from `instructions`.
            // Used when no prepared session was staged, and for the single
            // empty-response retry below.
            func makeSession() -> LanguageModelSession {
                LanguageModelSession(model: Self.summarizationModel(), instructions: instructions)
            }
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: maximumResponseTokens > 0 ? maximumResponseTokens : nil
            )
            do {
                let startedAt = ContinuousClock.now
                // Reuse the prewarmed prepared session only when it was staged
                // under the SAME instructions; otherwise the requested mode's
                // prompt (e.g. Both for a post+article summary) would be silently
                // ignored in favor of the prewarm's instructions.
                let prepared = preparedSessions.removeValue(forKey: identifier) as? LanguageModelSession
                let preparedMatches = preparedInstructions.removeValue(forKey: identifier) == instructions
                var session = (preparedMatches ? prepared : nil) ?? makeSession()
                var latest = ""
                var loggedFirstToken = false
                // The model very occasionally streams nothing and ends cleanly
                // (no thrown error, empty content). Retry once on a fresh session
                // before surfacing an "empty summary" error — the empty turn is not
                // fed back into the transcript that way.
                for attempt in 0..<2 {
                    if attempt > 0 {
                        session = makeSession()
                        latest = ""
                        aiLog.debug("empty response for \(identifier, privacy: .public); retrying once")
                    }
                    for try await snapshot in session.streamResponse(to: text, options: options) {
                        latest = snapshot.content
                        if !loggedFirstToken, !latest.isEmpty {
                            loggedFirstToken = true
                            let elapsed = ContinuousClock.now - startedAt
                            aiLog.debug("first text \(identifier, privacy: .public) after \(String(describing: elapsed), privacy: .public)")
                        }
                        onPartial(latest)
                    }
                    if !latest.isEmpty || Task.isCancelled { break }
                }
                // A cancellation can surface as a clean end-of-stream (the loop
                // finishing without `streamResponse` throwing `CancellationError`),
                // especially when the break above fires on `Task.isCancelled`.
                // Re-check here and route through the catch's code-6 sentinel
                // instead of falling through as an empty/partial success — otherwise
                // the ObjC side never sees the navigation-cancellation code and
                // marks the post failed/suppressed (and won't regenerate on reopen,
                // since `onComplete` lands after `viewDidDisappear` clears the set).
                if Task.isCancelled { throw CancellationError() }
                aiLog.debug("completed \(identifier, privacy: .public) after \(String(describing: ContinuousClock.now - startedAt), privacy: .public)")
                onComplete(latest, nil)
            } catch {
                preparedSessions.removeValue(forKey: identifier)
                preparedInstructions.removeValue(forKey: identifier)
                if Task.isCancelled {
                    onComplete(nil, Self.makeError(code: 6, message: "Generation cancelled"))
                } else {
                    onComplete(nil, Self.classify(error))
                }
            }
            activeTasks.removeValue(forKey: identifier)
        }
        activeTasks[identifier]?.cancel()
        activeTasks[identifier] = task
        #else
        onComplete(nil, Self.makeError(code: 4, message: "FoundationModels not available in this build"))
        #endif
    }

    /// Generate a Theme Builder palette as JSON. This is intentionally a
    /// one-shot completion API (no streaming UI): the Objective-C theme service
    /// owns validation, repair, saving, and presentation.
    @objc public func generateThemeJSON(withPrompt prompt: String,
                                        identifier: String,
                                        currentJSON: String,
                                        instruction: String,
                                        maximumResponseTokens: Int,
                                        onComplete: @escaping (String?, NSError?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            onComplete(nil, Self.makeError(code: 4, message: "Requires iOS 26 or later"))
            return
        }

        let systemInstructions = """
        You are Apollo Reborn's theme design assistant.

        Turn a short natural-language theme idea into a polished, readable app theme for a Reddit client used for long reading sessions. Usability matters as much as personality.

        Color intent — the single most important rule, and the one most often done badly:
        - Build the WHOLE palette from the colors people associate with the request — backgrounds, bars, and separators included, not just the accent. If it names a subject with signature colors (a red-and-blue hero, an autumn forest, a Game Boy), those colors must appear across the surfaces too.
        - background, secondaryBackground, tertiaryBackground, barsAndChrome, and separators MUST be tinted toward the theme's color family. "Calm" / "low saturation" means a deep, desaturated version of the theme's hue (for example a near-navy for a blue theme) — it does NOT mean neutral grey. Do not output neutral grey or near-black surfaces unless the request is explicitly grey, monochrome, minimal, or OLED/true-black. A theme whose backgrounds are plain grey has FAILED the request.
        - The accent is the most vivid color: the subject's boldest signature color.
        - Only the theme NAME must be original — never reuse a trademarked or official name. The palette itself should clearly evoke the request.

        Readability rules:
        - Primary text (near-white in dark mode, near-black in light mode, optionally tinted slightly toward the theme) must be clearly readable against every background and bar.
        - Secondary text must be clearly readable, not faint.
        - Light and dark mode should feel related but not merely inverted: dark mode uses deep tinted surfaces, light mode uses pale tinted surfaces, both sharing the accent.
        - Avoid muddy, chaotic, neon text, and low-contrast pastel-on-pastel palettes unless the user explicitly asks for chaos; contrast still matters.
        - Every color is a six-digit hex with a leading # and no transparency.
        - Do not use pure black unless the request explicitly asks for OLED, AMOLED, pure black, or true black.

        Worked examples (match this approach; choose your own exact hexes):
        - "Superman": dark mode = deep navy-blue backgrounds + a vivid red accent + near-white text; light mode = pale blue-white backgrounds + the same red accent. Recognizably red-and-blue, never grey.
        - "Cozy autumn": warm brown/amber backgrounds + a burnt-orange accent + cream text.
        - "Retro Game Boy": olive/pea-green surfaces + a deeper green accent, under a name like "Pocket Player".
        """

        let userPrompt: String
        if !currentJSON.isEmpty || !instruction.isEmpty {
            userPrompt = """
            Improve this existing Apollo Reborn Theme Builder result.

            User request:
            "\(instruction.isEmpty ? "Refine this theme while preserving its identity." : instruction)"

            Original idea:
            "\(prompt)"

            Existing theme JSON:
            \(currentJSON)

            Modify the existing theme rather than replacing it. Preserve the core identity unless the request asks for a major change. Return the full updated JSON object.
            """
        } else {
            userPrompt = """
            Create an Apollo Reborn theme from this user request:
            "\(prompt)"

            It should be usable immediately as a starting point in Theme Builder. Preserve the spirit of the request, but improve the palette where needed for readability, taste, and long-session comfort. Generate both light and dark mode palettes.
            """
        }

        let task = Task { @MainActor in
            // A little temperature (vs the previous .greedy) gives bolder, more
            // colourful palettes instead of the blandest safe default — greedy
            // tended to leave surfaces neutral grey — and makes "Regenerate"
            // actually produce a different theme each time.
            let options = GenerationOptions(
                temperature: 0.7,
                maximumResponseTokens: maximumResponseTokens > 0 ? maximumResponseTokens : nil
            )
            do {
                let startedAt = ContinuousClock.now
                let session = LanguageModelSession(model: Self.summarizationModel(), instructions: systemInstructions)
                // Guided generation: the model fills the ApolloGeneratedTheme
                // schema directly, so we never parse free-form text and the
                // palette can't drift into an invalid or off-purpose shape.
                let response = try await session.respond(to: userPrompt,
                                                         generating: ApolloGeneratedTheme.self,
                                                         options: options)
                if Task.isCancelled { throw CancellationError() }
                let json = Self.themeJSONString(from: response.content)
                aiLog.debug("theme generation completed promptLength=\(prompt.count, privacy: .public) after \(String(describing: ContinuousClock.now - startedAt), privacy: .public)")
                onComplete(json, nil)
            } catch {
                if Task.isCancelled {
                    onComplete(nil, Self.makeError(code: 6, message: "Generation cancelled"))
                } else {
                    onComplete(nil, Self.classify(error))
                }
            }
            activeTasks.removeValue(forKey: identifier)
        }
        activeTasks[identifier]?.cancel()
        activeTasks[identifier] = task
        #else
        onComplete(nil, Self.makeError(code: 4, message: "FoundationModels not available in this build"))
        #endif
    }

    private static func makeError(code: Int, message: String) -> NSError {
        return NSError(domain: "ApolloFoundationModels",
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if canImport(FoundationModels)
    /// Serialize a guided-generation result into the exact JSON shape the ObjC
    /// theme pipeline (ApolloThemeAI.m `ATBResultFromJSON`) already parses, so
    /// the Swift rewrite needs no downstream changes.
    @available(iOS 26.0, *)
    private static func themeJSONString(from theme: ApolloGeneratedTheme) -> String? {
        func palette(_ p: ApolloGeneratedPalette) -> [String: String] {
            return [
                "accent": p.accent,
                "background": p.background,
                "secondaryBackground": p.secondaryBackground,
                "tertiaryBackground": p.tertiaryBackground,
                "separators": p.separators,
                "barsAndChrome": p.barsAndChrome,
                "secondaryText": p.secondaryText,
                "text": p.text,
            ]
        }
        let root: [String: Any] = [
            "name": theme.name,
            "shortDescription": theme.shortDescription,
            "aestheticTags": theme.aestheticTags,
            "lightMode": palette(theme.lightMode),
            "darkMode": palette(theme.darkMode),
            "accessibilityNotes": theme.accessibilityNotes,
            "suggestedTweaks": theme.suggestedTweaks.map {
                ["title": $0.title, "instruction": $0.instruction]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif

    /// Map a thrown FoundationModels error to a stable integer code the ObjC
    /// side branches on (see `ApolloAIFriendlyError` / the transient-retry path
    /// in ApolloAISummary.xm). Classifying here, against the typed error enum,
    /// is robust across OS locales — the previous English substring matching on
    /// `localizedDescription` broke under localization. The original
    /// description is preserved for logging.
    ///
    /// We deliberately match only `LanguageModelSession.GenerationError`, the
    /// error type in the iOS 26 SDK we build against. iOS 27 introduced new
    /// types (`LanguageModelError`, `LanguageModelSession.Error`), but those do
    /// not exist in the build SDK, so referencing them fails to compile (a
    /// `#available` runtime check does not gate compile-time symbol lookup).
    /// `GenerationError` is deprecated-not-removed on iOS 27, so it still
    /// classifies there; anything unmatched falls through to code 5 and the
    /// ObjC side's generic message.
    ///   6  = cancelled            7  = guardrail / refusal
    ///   8  = context window full  9  = rate limited / concurrent (transient)
    ///   10 = unsupported language  2 = assets unavailable / model not ready
    ///   5  = unknown
    private static func classify(_ error: Error) -> NSError {
        var code = 5
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation, .refusal:      code = 7
            case .exceededContextWindowSize:         code = 8
            case .rateLimited, .concurrentRequests:  code = 9
            case .unsupportedLanguageOrLocale:       code = 10
            case .assetsUnavailable:                 code = 2
            default:                                 code = 5
            }
        }
        #endif
        let ns = error as NSError
        return NSError(domain: "ApolloFoundationModels",
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: ns.localizedDescription])
    }
}
