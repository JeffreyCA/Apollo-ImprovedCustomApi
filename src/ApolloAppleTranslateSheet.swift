//
//  ApolloAppleTranslateSheet.swift
//  Apollo-Reborn
//
//  Presents iOS's native Translate sheet (Translation.framework) as an
//  alternative to Apollo's OWN Translate button, which normally opens
//  `_TtC6Apollo24TranslatorViewController` — a `WKWebView` loading
//  translate.google.com. `ApolloAppleTranslateSheet.xm` intercepts that
//  presentation and calls into this file when the user has opted in.
//
//  NOT guaranteed on-device. Unlike ApolloAppleTranslationCoordinator below,
//  which only ever drives a headless `TranslationSession` against already-
//  installed models, `.translationPresentation` is a system UI that may, by
//  default, send the text to Apple's servers to translate (confirmed on-device:
//  the sheet shows its own one-time "will be sent to Apple to process" consent
//  prompt) unless the user has enabled offline-only translation in the system
//  Translate app's settings. Don't describe this feature as private in any
//  user-facing copy.
//
//  Why a hidden SwiftUI host? Same reason as ApolloAppleTranslation.swift: Apple's
//  Translate UI has no UIKit entry point. It's exposed ONLY as the SwiftUI view
//  modifier `.translationPresentation(isPresented:text:)`, so a real (if invisible)
//  SwiftUI view has to exist in the hierarchy to carry it.
//
//  This is deliberately a SEPARATE host from ApolloAppleTranslationCoordinator's
//  (ApolloAppleTranslation.swift) — that one is a long-lived singleton whose
//  re-renders are load-bearing for vending `TranslationSession`s for the bulk
//  in-place pipeline. This one is short-lived: it exists only for the duration of
//  one Translate-button tap and tears itself down when the sheet is dismissed.
//
//  `.translationPresentation` is available from iOS 17.4 — earlier than the iOS
//  18.0 floor `TranslationSession`/`.translationTask` need in the other file — so
//  this feature has its own, lower availability gate.
//

import Foundation

#if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
import UIKit
import SwiftUI
import Translation
import os

@available(iOS 17.4, *)
private let appleTranslateSheetLog = Logger(subsystem: "apollofix", category: "AppleTranslateSheet")

// MARK: - Hidden host

/// Sized to fill the presenter's view (not a 1x1 pixel) so that on iPad — where
/// `.translationPresentation` shows a POPOVER rather than a sheet — it anchors
/// somewhere reasonable instead of the top-left corner.
@available(iOS 17.4, *)
private struct ApolloTranslateSheetHost: View {
    let text: String
    let onDismiss: () -> Void
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text)
            .onAppear { isPresented = true }
            .onChange(of: isPresented) { _, presented in
                if !presented { onDismiss() }
            }
    }
}

/// Owns the hidden host's lifecycle. Not actor-isolated: every entry point here is
/// only ever reached synchronously from the main-thread `presentViewController:`
/// hook in ApolloAppleTranslateSheet.xm, and touches only UIKit view-hierarchy
/// APIs (no async Translation-framework calls happen in this file).
@available(iOS 17.4, *)
private final class ApolloTranslateSheetPresentation {
    private weak var hosting: UIHostingController<ApolloTranslateSheetHost>?

    /// Only one sheet host at a time — a second tap while one is already up
    /// declines, so the caller falls back to Apollo's web view rather than this
    /// file stacking a second hidden host.
    private var isActive: Bool { hosting != nil }

    func present(_ text: String, from presenter: UIViewController) -> Bool {
        guard !isActive else {
            appleTranslateSheetLog.log("Apple translate sheet already active; declining second presentation")
            return false
        }

        let host = UIHostingController(
            rootView: ApolloTranslateSheetHost(text: text, onDismiss: { [weak self] in
                self?.teardown()
            })
        )
        host.view.frame = presenter.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false

        presenter.addChild(host)
        presenter.view.addSubview(host.view)
        host.didMove(toParent: presenter)

        hosting = host
        appleTranslateSheetLog.log("presented Apple translate sheet for \(text.count, privacy: .public) chars")
        return true
    }

    private func teardown() {
        guard let host = hosting else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        hosting = nil
        appleTranslateSheetLog.log("Apple translate sheet dismissed")
    }
}

@available(iOS 17.4, *)
private let sharedPresentation = ApolloTranslateSheetPresentation()

#endif

// MARK: - Objective-C bridge

/// Stable, always-present Objective-C entry point — defined unconditionally (no
/// `@available` on the class) so the generated `ApolloReborn-Swift.h` always
/// declares it; the iOS-17.4 gate lives inside each method. Mirrors
/// `ApolloAppleTranslator` in ApolloAppleTranslation.swift.
@objc(ApolloAppleTranslateSheet)
public final class ApolloAppleTranslateSheet: NSObject {

    /// Whether the native Translate sheet (Translation.framework's
    /// `.translationPresentation`) can be presented on this OS.
    @objc public static func isSupported() -> Bool {
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 17.4, *) { return true }
        #endif
        return false
    }

    /// Presents the native Translate sheet for `text`, hosted as a hidden child of
    /// `presenter`. Returns NO (declining) when unsupported, `text` is empty, or a
    /// sheet is already active — the caller should fall back to Apollo's own web
    /// view in that case.
    @objc public static func present(_ text: String, from presenter: UIViewController) -> Bool {
        guard !text.isEmpty else { return false }
        #if canImport(Translation) && canImport(SwiftUI) && canImport(UIKit)
        if #available(iOS 17.4, *) {
            return sharedPresentation.present(text, from: presenter)
        }
        #endif
        return false
    }
}
