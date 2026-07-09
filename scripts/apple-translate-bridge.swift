// apple-translate-bridge — host-side Apple translation for SIMULATOR testing.
//
// Apple's Translation framework does not exist inside iOS simulator runtimes
// (LanguageAvailability reports .unsupported for every pair), but the exact
// same engine ships on macOS. This tiny server runs ON THE MAC and exposes it
// over loopback so the tweak's APOLLO_SIM_BUILD Apple provider can translate
// for real while running in the simulator. Dev tooling only — never shipped.
//
//   swiftc -O -parse-as-library scripts/apple-translate-bridge.swift -o .sim/apple-bridge
//   .sim/apple-bridge            # listens on 127.0.0.1:8765
//
//   POST /translate  {"q":"...","source":"pt","target":"en"} -> {"translatedText":"..."}
//   GET  /status?source=pt&target=en                         -> {"status":"installed|supported|unsupported"}
//
// Pairs reported "supported" need a one-time download on the Mac:
// System Settings → General → Language & Region → Translation Languages.

import Foundation
import Network
import Translation

@available(macOS 26.0, *)
actor Translator {
    private var sessions: [String: TranslationSession] = [:]

    private func lang(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code)
    }

    func status(source: String, target: String) async -> String {
        let s = await LanguageAvailability().status(from: lang(source), to: lang(target))
        switch s {
        case .installed: return "installed"
        case .supported: return "supported"
        default: return "unsupported"
        }
    }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        let key = "\(source)>\(target)"
        if sessions[key] == nil {
            let st = await status(source: source, target: target)
            guard st == "installed" else {
                throw NSError(domain: "bridge", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    st == "supported"
                        ? "\(source)->\(target) needs a one-time download on the Mac: System Settings → General → Language & Region → Translation Languages"
                        : "\(source)->\(target) unsupported by Apple Translation"])
            }
            sessions[key] = TranslationSession(installedSource: lang(source), target: lang(target))
        }
        // The engine occasionally throws transient "Unable to Translate" under
        // serial load (same behaviour as on-device) — retry once.
        var attempt = 0
        while true {
            do {
                return try await sessions[key]!.translate(text).targetText
            } catch {
                attempt += 1
                if attempt >= 2 { throw error }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

@available(macOS 26.0, *)
@main
struct Bridge {
    static let translator = Translator()

    static func main() async throws {
        let port: UInt16 = 8765
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Task { await handle(conn) }
        }
        listener.start(queue: .main)
        print("apple-translate-bridge listening on 127.0.0.1:\(port)")
        try await Task.sleep(nanoseconds: .max)
    }

    // Minimal single-request HTTP handling (Connection: close semantics).
    static func handle(_ conn: NWConnection) async {
        var buffer = Data()
        while true {
            guard let chunk = await receive(conn) else { break }
            buffer.append(chunk)
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = head
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyStart = headerEnd.upperBound
            if buffer.count - bodyStart < contentLength { continue }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
            await respond(conn, requestLine: requestLine, body: body)
            break
        }
    }

    static func receive(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete || error != nil { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    static func respond(_ conn: NWConnection, requestLine: String, body: Data) async {
        var status = "200 OK"
        var payload: [String: Any] = [:]

        if requestLine.hasPrefix("POST /translate") {
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let q = obj["q"] as? String,
               let source = obj["source"] as? String,
               let target = obj["target"] as? String {
                do {
                    payload["translatedText"] = try await translator.translate(q, source: source, target: target)
                } catch {
                    status = "502 Bad Gateway"
                    payload["error"] = error.localizedDescription
                }
            } else {
                status = "400 Bad Request"
                payload["error"] = "expected JSON {q, source, target}"
            }
        } else if requestLine.hasPrefix("GET /status") {
            let comps = URLComponents(string: String(requestLine.split(separator: " ")[1]))
            let source = comps?.queryItems?.first { $0.name == "source" }?.value ?? ""
            let target = comps?.queryItems?.first { $0.name == "target" }?.value ?? ""
            payload["status"] = await translator.status(source: source, target: target)
            payload["source"] = source
            payload["target"] = target
        } else {
            status = "404 Not Found"
            payload["error"] = "unknown endpoint"
        }

        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        // Cancel only after the reply has flushed — cancelling immediately
        // races the send and the client sees an empty reply.
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}
