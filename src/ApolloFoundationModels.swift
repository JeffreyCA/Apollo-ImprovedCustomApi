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

// Theme generation asks the model for THREE SEED COLOURS only (plain text in,
// "three hex codes" out — see ApolloThemeAI.m, which owns the prompt template
// and parses defensively); a deterministic on-device engine
// (ApolloThemePaletteEngine) derives the full palettes. Three earlier designs
// asked the model for progressively less palette judgement — a structured
// colour brief, a directly-typed hex-per-role schema, then unconstrained
// per-role JSON — and all three produced unreliable palettes: the on-device
// model is good at recalling a subject's iconic colours and bad at
// composing a readable UI from them. So the bridge is now a single generic
// plain-completion call with no theme-specific knowledge at all.

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

    /// Pre-build (and prewarm) the plain no-instructions session the next
    /// `plainCompletion` for `identifier` will use. Session construction +
    /// guardrail preparation cost real time on older devices; calling this
    /// when the prompt UI OPENS hides that entirely behind the user's typing.
    @objc public func prewarmPlainSession(_ identifier: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard !identifier.isEmpty, preparedSessions[identifier] == nil else { return }
            let session = LanguageModelSession(model: Self.summarizationModel())
            preparedSessions[identifier] = session
            preparedInstructions[identifier] = "" // sentinel: plain (no instructions)
            session.prewarm()
        }
        #endif
    }

    /// One-shot plain completion: a fresh session with NO system instructions,
    /// `prompt` in, the model's literal text out. This is the exact shape the
    /// model handles most reliably (matches the system "Use On-Device model"
    /// Shortcuts action, validated by hand) — the theme feature uses it to ask
    /// for three iconic seed colours, but nothing here is theme-specific.
    /// Temperature is modest but non-zero so "Regenerate" can land on a
    /// different (still iconic) answer. Callbacks land on the main thread.
    @objc public func plainCompletion(_ prompt: String,
                                      identifier: String,
                                      onComplete: @escaping (String?, NSError?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            onComplete(nil, Self.makeError(code: 4, message: "Requires iOS 26 or later"))
            return
        }
        // Consume a prewarmed plain session if one was staged for this id
        // (empty-string instructions sentinel — never an instructed one).
        let prepared = preparedSessions.removeValue(forKey: identifier) as? LanguageModelSession
        let preparedIsPlain = preparedInstructions.removeValue(forKey: identifier) == ""
        let task = Task { @MainActor in
            do {
                if Task.isCancelled { throw CancellationError() }
                let startedAt = ContinuousClock.now
                let session = (preparedIsPlain ? prepared : nil)
                    ?? LanguageModelSession(model: Self.summarizationModel())
                let options = GenerationOptions(temperature: 0.7)
                aiLog.debug("plain completion REQUEST \(identifier, privacy: .public): \(prompt, privacy: .public)")
                let response = try await session.respond(to: prompt, options: options)
                aiLog.debug("plain completion RESPONSE \(identifier, privacy: .public) after \(String(describing: ContinuousClock.now - startedAt), privacy: .public): \(response.content, privacy: .public)")
                if Task.isCancelled { throw CancellationError() }
                onComplete(response.content, nil)
            } catch {
                aiLog.debug("plain completion ERROR \(identifier, privacy: .public): \(String(describing: error), privacy: .public)")
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
