import AppKit

/// Orchestriert den Diktat-Ablauf: Hotkey runter → Aufnahme + Session,
/// Hotkey hoch → Transkript holen → Text einfügen.
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        /// Text steht bereit, Einfügen ist blockiert — Watcher schiebt nach.
        case waiting(String)
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
    private var pendingInsert: Task<Void, Never>?

    /// Kurzer Tap statt Halten → Aufnahme läuft freihändig weiter,
    /// der nächste Tap beendet sie (wie bei Wispr Flow).
    private var handsFree = false
    private var suppressNextUp = false
    private let handsFreeTapThreshold: TimeInterval = 0.4

    func hotkeyDown() {
        // Zweiter Tap im Hands-free-Modus beendet die Aufnahme.
        if state == .recording, handsFree {
            suppressNextUp = true
            finishRecording()
            return
        }
        guard canStartRecording else { return }
        pendingInsert?.cancel()
        pendingInsert = nil
        handsFree = false

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
        if suppressNextUp {
            suppressNextUp = false
            return
        }
        guard state == .recording else { return }

        // Kurzer Tap → freihändig weiter aufnehmen statt stoppen.
        let heldDuration = Date().timeIntervalSince(recordingStart ?? Date())
        if heldDuration < handsFreeTapThreshold {
            handsFree = true
            FlowLog.log("Hands-free: Aufnahme läuft weiter — Hotkey erneut tippen zum Stoppen.")
            return
        }
        finishRecording()
    }

    private func finishRecording() {
        guard state == .recording, let session else { return }
        handsFree = false
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
                StatsStore.shared.record(text: text, duration: duration, appName: context?.appName ?? "Unbekannt")
                do {
                    try TextInserter.insert(text)
                    self?.state = .idle
                } catch let insertError as TextInserter.InsertError {
                    self?.beginPendingInsert(text: text, message: insertError.waitingMessage)
                }
            } catch {
                NSSound(named: "Basso")?.play()
                self?.state = .error(error.localizedDescription)
            }
            self?.session = nil
        }
    }

    /// Wartet darauf, dass Secure Input freigegeben wird, und fügt den Text
    /// dann automatisch ein — solange der Nutzer in derselben App geblieben ist.
    private func beginPendingInsert(text: String, message: String) {
        pendingInsert?.cancel()
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state = .waiting(message)
        pendingInsert = Task { @MainActor [weak self] in
            for _ in 0..<240 { // bis zu 2 Minuten, alle 0,5 s
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard !TextInserter.isSecureInputBlocked() else { continue }

                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid,
                   (try? TextInserter.insert(text)) != nil {
                    FlowLog.log("Nachträglich eingefügt — Secure Input wurde freigegeben.")
                    self.state = .idle
                } else {
                    self.state = .error("Secure Input ist frei — Text liegt in der Zwischenablage (⌘V).")
                }
                return
            }
            self?.state = .error("Weiter blockiert — Text liegt in der Zwischenablage (⌘V).")
        }
    }

    private var canStartRecording: Bool {
        switch state {
        case .idle, .error, .waiting: return true
        case .recording, .transcribing: return false
        }
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
