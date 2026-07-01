import Foundation

/// Kontext der aktuellen Diktat-Session — wird an Cloud-Engines weitergereicht,
/// damit sie Stil und Schreibweise anpassen können (Wispr-API-Feature).
struct DictationContext {
    var appName: String
    var appType: String // "email" | "ai" | "other"
    var language: [String]
    var dictionary: [String]
    var userFirstName: String
    var userLastName: String
}

enum TranscriptionError: LocalizedError {
    case missingApiKey(String)
    case server(String)
    case timeout
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingApiKey(let engine): return "Kein API-Key für \(engine) hinterlegt (Einstellungen)."
        case .server(let message): return message
        case .timeout: return "Zeitüberschreitung bei der Transkription."
        case .emptyResult: return "Kein Text erkannt."
        }
    }
}

/// Eine Session lebt von Hotkey-Down bis zum fertigen Transkript.
/// Streaming-Engines (Wispr) senden Pakete live, Batch-Engines sammeln
/// und transkribieren erst in `finish()`.
protocol TranscriptionSession: AnyObject {
    /// 50-ms-Paket, 16 kHz mono Int16. Wird vom Audio-Thread aufgerufen.
    func append(packet: [Int16], volume: Float)
    /// Aufnahme beendet — liefert das finale Transkript.
    func finish() async throws -> String
    /// Abbruch (z. B. zu kurze Aufnahme).
    func cancel()
}

protocol TranscriptionEngine {
    var kind: EngineKind { get }
    /// Muss sofort zurückkehren; Verbindungsaufbau passiert intern asynchron,
    /// eingehende Pakete werden bis dahin gepuffert.
    func makeSession(context: DictationContext) -> TranscriptionSession
}

func makeEngine(_ kind: EngineKind) -> TranscriptionEngine {
    switch kind {
    case .local: return LocalParakeetEngine.shared
    case .wispr: return WisprFlowEngine()
    case .elevenlabs: return ElevenLabsEngine()
    }
}

/// Kleiner Timeout-Helfer für die Cloud-Aufrufe.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranscriptionError.timeout
        }
        guard let result = try await group.next() else { throw TranscriptionError.timeout }
        group.cancelAll()
        return result
    }
}
