import Foundation

/// Streaming-Client für die offizielle Wispr-Flow-API
/// (https://api-docs.wisprflow.ai): WebSocket, 50-ms-PCM-Pakete als Base64,
/// Ablauf auth → append… → commit → finales Transkript.
final class WisprFlowEngine: TranscriptionEngine {
    let kind: EngineKind = .wispr

    func makeSession(context: DictationContext) -> TranscriptionSession {
        WisprSession(context: context)
    }
}

private final class WisprSession: NSObject, TranscriptionSession {
    private let context: DictationContext
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    private let lock = NSLock()
    private var authed = false
    private var queued: [(packet: [Int16], volume: Float)] = []
    private var packetsSent = 0
    private var lastText: String?
    private var failure: Error?
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var finished = false

    init(context: DictationContext) {
        self.context = context
        super.init()
        connect()
    }

    // MARK: Verbindung

    private func connect() {
        let apiKey = AppSettings.wisprApiKey
        guard !apiKey.isEmpty else {
            fail(TranscriptionError.missingApiKey("Wispr Flow"))
            return
        }

        var components = URLComponents(string: "wss://platform-api.wisprflow.ai/api/v1/dash/ws")!
        components.queryItems = [URLQueryItem(name: "api_key", value: "Bearer \(apiKey)")]
        guard let url = components.url else {
            fail(TranscriptionError.server("Ungültige Wispr-URL."))
            return
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()

        sendAuth()
        receiveLoop()
    }

    private func sendAuth() {
        var languages: [String] = []
        if !context.language.isEmpty { languages = context.language }

        let message: [String: Any] = [
            "type": "auth",
            "language": languages,
            "context": [
                "app": ["name": context.appName, "type": context.appType],
                "dictionary_context": context.dictionary,
                "user_first_name": context.userFirstName,
                "user_last_name": context.userLastName,
                "textbox_contents": [
                    "before_text": "",
                    "selected_text": "",
                    "after_text": "",
                ],
            ] as [String: Any],
        ]
        send(json: message)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleClosed(error: error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handle(messageText: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handle(messageText: text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(messageText: String) {
        guard let data = messageText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let errorMessage = json["error"] as? String {
            fail(TranscriptionError.server("Wispr: \(errorMessage)"))
            return
        }

        switch json["status"] as? String {
        case "auth":
            drainQueueAfterAuth()
        case "text":
            let body = json["body"] as? [String: Any]
            let text = (body?["text"] as? String) ?? ""
            let isFinal = (json["final"] as? Bool) ?? false
            lock.lock()
            if !text.isEmpty { lastText = text }
            let continuation = isFinal ? takeContinuationLocked() : nil
            let finalText = lastText
            lock.unlock()
            if let continuation, let finalText {
                continuation.resume(returning: finalText)
                close()
            }
        default:
            break // "info"-Events (session_started, commit_received) ignorieren
        }
    }

    // MARK: Audio

    func append(packet: [Int16], volume: Float) {
        lock.lock()
        if !authed || failure != nil {
            queued.append((packet, volume))
            lock.unlock()
            return
        }
        let position = packetsSent
        packetsSent += 1
        lock.unlock()
        send(packet: packet, volume: volume, position: position)
    }

    private func drainQueueAfterAuth() {
        lock.lock()
        authed = true
        let pending = queued
        queued.removeAll()
        var position = packetsSent
        packetsSent += pending.count
        lock.unlock()

        for item in pending {
            send(packet: item.packet, volume: item.volume, position: position)
            position += 1
        }
    }

    private func send(packet: [Int16], volume: Float, position: Int) {
        let base64 = WavEncoder.rawBytes(samples: packet).base64EncodedString()
        let message: [String: Any] = [
            "type": "append",
            "position": position,
            "audio_packets": [
                "packets": [base64],
                "volumes": [Double(volume)],
                "packet_duration": Double(AudioRecorder.packetSamples) / AudioRecorder.sampleRate,
                "audio_encoding": "wav",
                "byte_encoding": "base64",
            ] as [String: Any],
        ]
        send(json: message)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    // MARK: Abschluss

    func finish() async throws -> String {
        try await withTimeout(seconds: 15) { [self] in
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                finishContinuation = continuation
                let total = packetsSent + queued.count
                lock.unlock()
                send(json: ["type": "commit", "total_packets": total])
            }
        }
    }

    func cancel() {
        close()
    }

    private func close() {
        lock.lock()
        finished = true
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let continuation = takeContinuationLocked()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func handleClosed(error: Error) {
        lock.lock()
        let alreadyFinished = finished
        let continuation = takeContinuationLocked()
        let text = lastText
        lock.unlock()

        guard !alreadyFinished else { return }
        // Server hat geschlossen: letztes Transkript ist das Ergebnis.
        if let continuation {
            if let text {
                continuation.resume(returning: text)
            } else {
                continuation.resume(throwing: error)
            }
        } else {
            fail(error)
        }
    }

    private func takeContinuationLocked() -> CheckedContinuation<String, Error>? {
        let continuation = finishContinuation
        finishContinuation = nil
        return continuation
    }
}
