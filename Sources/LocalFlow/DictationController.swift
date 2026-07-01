import AppKit

/// Orchestriert den Diktat-Ablauf: Hotkey runter → Aufnahme + Session,
/// Hotkey hoch → Transkript holen → Text einfügen.
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    private(set) var state: State = .idle {
        didSet {
            FlowLog.log("state → \(state)")
            onStateChange?(state)
        }
    }
    var onStateChange: ((State) -> Void)?
    /// Aufnahmepegel 0…1, ~20×/s — für die HUD-Pegelanzeige.
    var onLevel: ((Float) -> Void)?

    private let recorder = AudioRecorder()
    private var session: TranscriptionSession?
    private var recordingStart: Date?
    private var packetCount = 0

    /// Aufnahmen unter 0,3 s sind fast immer versehentliche Tastendrücke.
    private let minimumDuration: TimeInterval = 0.3

    private var context: DictationContext?

    func hotkeyDown() {
        guard state == .idle || isErrorState else { return }

        let context = ContextCapture.capture()
        self.context = context
        let engine = makeEngine(AppSettings.engine)
        let session = engine.makeSession(context: context)
        self.session = session
        packetCount = 0

        recorder.onPacket = { [weak self] packet, volume in
            self?.packetCount += 1
            session.append(packet: packet, volume: volume)
            self?.onLevel?(volume)
        }

        do {
            try recorder.start()
            recordingStart = Date()
            state = .recording
        } catch {
            session.cancel()
            self.session = nil
            state = .error(error.localizedDescription)
        }
    }

    func hotkeyUp() {
        guard state == .recording, let session else { return }
        recorder.stop()

        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= minimumDuration else {
            session.cancel()
            self.session = nil
            state = .idle
            return
        }

        state = .transcribing
        let context = self.context
        Task { @MainActor [weak self] in
            do {
                // Watchdog: keine Session darf die App dauerhaft blockieren.
                var text = try await withTimeout(seconds: 60) { try await session.finish() }
                text = await Self.applyCleanup(to: text, context: context)
                FlowLog.log("Transkript (\(text.count) Zeichen): \(text.prefix(120))")
                try TextInserter.insert(text)
                self?.state = .idle
            } catch {
                NSSound(named: "Basso")?.play()
                self?.state = .error(error.localizedDescription)
            }
            self?.session = nil
        }
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    /// Auto-Edit: Selbstkorrekturen und Füllwörter per LLM auflösen.
    /// Nur für Engines mit rohem Transkript — Wispr bereinigt serverseitig.
    /// Scheitert der Cleanup, wird das rohe Transkript eingefügt.
    private static func applyCleanup(to text: String, context: DictationContext?) async -> String {
        guard AppSettings.engine != .wispr,
              let cleaner = makeCleaner(AppSettings.cleanupMode),
              let context else { return text }
        do {
            let cleaned = try await cleaner.clean(text, context: context)
            FlowLog.log("Auto-Edit (\(AppSettings.cleanupMode.rawValue)): \"\(text)\" → \"\(cleaned)\"")
            return cleaned
        } catch {
            FlowLog.log("Auto-Edit fehlgeschlagen, nutze rohes Transkript: \(error.localizedDescription)")
            return text
        }
    }
}
