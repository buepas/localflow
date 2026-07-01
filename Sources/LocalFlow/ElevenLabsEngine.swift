import Foundation

/// Batch-Client für ElevenLabs Scribe (v2): Aufnahme sammeln, als WAV
/// per multipart/form-data hochladen. `no_verbatim` entfernt Füllwörter —
/// das kommt dem Wispr-"Auto-Edit" am nächsten.
final class ElevenLabsEngine: TranscriptionEngine {
    let kind: EngineKind = .elevenlabs

    func makeSession(context: DictationContext) -> TranscriptionSession {
        ElevenLabsSession(context: context)
    }
}

private final class ElevenLabsSession: TranscriptionSession {
    private let context: DictationContext
    private var samples: [Int16] = []
    private let lock = NSLock()

    init(context: DictationContext) {
        self.context = context
    }

    func append(packet: [Int16], volume: Float) {
        lock.lock()
        samples.append(contentsOf: packet)
        lock.unlock()
    }

    private func snapshotSamples() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func finish() async throws -> String {
        let apiKey = AppSettings.elevenLabsApiKey
        guard !apiKey.isEmpty else { throw TranscriptionError.missingApiKey("ElevenLabs") }

        let collected = snapshotSamples()

        let wav = WavEncoder.encode(samples: collected)
        let boundary = "localflow-\(UUID().uuidString)"

        var fields: [(name: String, value: String)] = [("model_id", "scribe_v2")]
        if let language = context.language.first {
            fields.append(("language_code", language))
        }
        if AppSettings.elevenLabsRemoveFillers {
            fields.append(("no_verbatim", "true"))
        }
        fields.append(("tag_audio_events", "false"))
        if !context.dictionary.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: context.dictionary),
           let keyterms = String(data: keytermsData, encoding: .utf8) {
            fields.append(("keyterms", keyterms))
        }

        var body = Data()
        for field in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8))
            body.append(Data("\(field.value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let preparedRequest = request

        let (data, response) = try await withTimeout(seconds: 30) {
            try await URLSession.shared.data(for: preparedRequest)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.server("ElevenLabs HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(detail.prefix(300))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return text
    }

    func cancel() {}
}
