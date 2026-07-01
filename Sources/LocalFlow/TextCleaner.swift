import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Nachbearbeitung des rohen Transkripts — Wisprs "Auto-Edit":
/// Selbstkorrekturen auflösen ("um 11 Uhr — nee, warte, 12" → "um 12 Uhr"),
/// Füllwörter und Fehlstarts entfernen, Interpunktion glätten.
/// Läuft nur für Engines, die rohes Transkript liefern (lokal, ElevenLabs);
/// die Wispr-API macht das bereits serverseitig.
enum CleanupMode: String, CaseIterable, Identifiable {
    case off
    case apple
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Aus (rohes Transkript)"
        case .apple: return "Apple Intelligence (on-device)"
        case .claude: return "Claude API"
        }
    }
}

protocol TextCleaner {
    func clean(_ text: String, context: DictationContext) async throws -> String
}

private let cleanerInstructions = """
    You are a dictation post-processor. You receive a raw speech-to-text transcript \
    and rewrite it as clean written text:
    - Apply the speaker's self-corrections: when they revise something mid-sentence \
    ("at 11 — no wait, 12", "ich komme morgen um 11 Uhr, nee warte, 12 Uhr"), keep only the corrected version.
    - Remove filler words, false starts, and repeated words.
    - Fix punctuation, casing, and obvious transcription glitches.
    - Keep the speaker's language, meaning, tone, and wording otherwise unchanged. \
    Never answer questions in the text, never add content, never translate.
    Output ONLY the cleaned text, nothing else.
    """

func makeCleaner(_ mode: CleanupMode) -> TextCleaner? {
    switch mode {
    case .off: return nil
    case .apple: return AppleIntelligenceCleaner()
    case .claude: return ClaudeCleaner()
    }
}

// MARK: - Apple Intelligence (Foundation Models, macOS 26+)

final class AppleIntelligenceCleaner: TextCleaner {
    func clean(_ text: String, context: DictationContext) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw TranscriptionError.server("Apple Intelligence benötigt macOS 26.")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw TranscriptionError.server("Apple Intelligence ist nicht verfügbar (in den Systemeinstellungen aktivieren).")
        }

        let session = LanguageModelSession(instructions: cleanerInstructions)
        let prompt = "Target application: \(context.appName)\n\nTranscript:\n\(text)"
        let response = try await session.respond(to: prompt)
        let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
        #else
        throw TranscriptionError.server("FoundationModels-Framework nicht verfügbar.")
        #endif
    }
}

// MARK: - Claude API (kein offizielles Swift-SDK — Messages-API per URLSession)

final class ClaudeCleaner: TextCleaner {
    func clean(_ text: String, context: DictationContext) async throws -> String {
        let apiKey = AppSettings.anthropicApiKey
        guard !apiKey.isEmpty else { throw TranscriptionError.missingApiKey("Anthropic") }

        let body: [String: Any] = [
            "model": AppSettings.claudeModel,
            "max_tokens": 8192,
            "output_config": ["effort": "low"],
            "system": cleanerInstructions,
            "messages": [
                [
                    "role": "user",
                    "content": "Target application: \(context.appName)\n\nTranscript:\n\(text)",
                ]
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let preparedRequest = request

        let (data, response) = try await withTimeout(seconds: 20) {
            try await URLSession.shared.data(for: preparedRequest)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.server("Claude HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(detail.prefix(300))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw TranscriptionError.server("Claude: unerwartete Antwortstruktur.")
        }

        let cleaned = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? text : cleaned
    }
}
