import Foundation

/// Persönliches Transkript-Archiv: Jedes Diktat wird als eine JSON-Zeile an
/// ~/Library/Application Support/LocalFlow/transcripts.jsonl angehängt —
/// als eigener Text-Korpus für spätere Auswertung. Die Inhalte bleiben
/// vollständig auf diesem Mac; abschaltbar in den Einstellungen.
struct TranscriptEntry: Codable {
    var timestamp: String // ISO 8601 mit lokalem UTC-Offset
    var text: String
    /// Roh-Transkript vor Auto-Edit — nur gesetzt, wenn es sich vom finalen Text unterscheidet.
    var rawText: String?
    var appName: String
    var engine: String
    var durationSeconds: Double
    var language: String // Einstellung, "" = automatische Erkennung
    var words: Int
    var characters: Int
}

final class TranscriptStore {
    static let shared = TranscriptStore()

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.jsonl")
    }()

    private let queue = DispatchQueue(label: "ai.evalent.localflow.transcripts")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private init() {}

    func record(text: String, rawText: String, duration: TimeInterval, context: DictationContext?) {
        guard AppSettings.saveTranscripts else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = TranscriptEntry(
            timestamp: Self.timestampFormatter.string(from: Date()),
            text: text,
            rawText: rawText == text ? nil : rawText,
            appName: context?.appName ?? "Unbekannt",
            engine: AppSettings.engine.rawValue,
            durationSeconds: (duration * 100).rounded() / 100,
            language: AppSettings.language,
            words: text.split(whereSeparator: \.isWhitespace).count,
            characters: text.count
        )

        queue.async { [encoder] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: Self.fileURL)
            }
        }
    }
}
