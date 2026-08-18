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
        /// Trello-Karte angelegt — kurze Bestätigung, dann zurück zu idle.
        case success(String)
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
    /// Per Fn+Ctrl-Chord angefordert: Diktat wird Trello-Karte.
    private var trelloRequested = false
    /// Erkennt ein von Hand gedrücktes ⌘V, während wir noch auf ein Ziel
    /// warten — nur während `beginPendingInsert` aktiv.
    private var manualPasteMonitor: Any?

    func hotkeyDown() {
        guard canStartRecording else { return }
        pendingInsert?.cancel()
        pendingInsert = nil
        stopManualPasteWatch()
        trelloRequested = false

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
        guard state == .recording else { return }
        finishRecording()
    }

    /// Vom HotkeyMonitor bei Hotkey+Ctrl gemeldet.
    func markTrello() {
        guard state == .recording else { return }
        trelloRequested = true
        FlowLog.log("Trello-Modus per Chord aktiviert.")
    }

    /// Bricht ein bereits gestartetes Diktat ab, wenn sich der Hotkey als Teil
    /// einer normalen Tastenkombination herausstellt (z. B. Fn-F12).
    func hotkeyCancel() {
        guard state == .recording else { return }
        recorder.stop()
        session?.cancel()
        session = nil
        recordingStart = nil
        context = nil
        state = .idle
        FlowLog.log("Diktat wegen Tastenkombination abgebrochen.")
    }

    private func finishRecording() {
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
                let rawText = text
                text = await Self.applyCleanup(to: text, context: context)
                FlowLog.log("Transkript (\(text.count) Zeichen): \(text.prefix(120))")
                StatsStore.shared.record(text: text, duration: duration, appName: context?.appName ?? "Unbekannt")
                TranscriptStore.shared.record(text: text, rawText: rawText, duration: duration, context: context)
                if let todoText = Self.trelloText(cleaned: text, raw: rawText, viaChord: self?.trelloRequested == true) {
                    await self?.postTrelloCard(text: todoText)
                } else {
                    // Vor dem ersten Versuch einfangen — bei einem späteren
                    // Nachschiebe-Versuch läge sonst schon der diktierte Text
                    // selbst in der Zwischenablage.
                    let previousClipboard = NSPasteboard.general.string(forType: .string)
                    do {
                        try TextInserter.insert(text, restoring: previousClipboard)
                        self?.state = .idle
                    } catch let insertError as TextInserter.InsertError {
                        self?.beginPendingInsert(text: text, message: insertError.waitingMessage, previousClipboard: previousClipboard)
                    }
                }
            } catch {
                NSSound(named: "Basso")?.play()
                self?.state = .error(error.localizedDescription)
            }
            self?.session = nil
        }
    }

    /// Wartet darauf, dass Secure Input freigegeben oder ein Feld fokussiert
    /// wird, und fügt den Text dann automatisch ein — solange der Nutzer in
    /// derselben App geblieben ist. Versucht bei jedem Fehlschlag erneut,
    /// nicht nur einmalig beim ersten "vermutlich frei"-Zeitpunkt.
    private func beginPendingInsert(text: String, message: String, previousClipboard: String?) {
        pendingInsert?.cancel()
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state = .waiting(message)
        watchForManualPaste(targetPid: targetPid, previousClipboard: previousClipboard)
        pendingInsert = Task { @MainActor [weak self] in
            for _ in 0..<240 { // bis zu 2 Minuten, alle 0,5 s
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else {
                    self.stopManualPasteWatch()
                    self.state = .error("App gewechselt — Text liegt in der Zwischenablage (⌘V).")
                    return
                }
                do {
                    try TextInserter.insert(text, restoring: previousClipboard)
                    FlowLog.log("Nachträglich eingefügt.")
                    self.stopManualPasteWatch()
                    self.state = .idle
                    return
                } catch {
                    continue
                }
            }
            self?.stopManualPasteWatch()
            self?.state = .error("Weiter blockiert — Text liegt in der Zwischenablage (⌘V).")
        }
    }

    /// Merkt sich ein von Hand gedrücktes ⌘V in derselben Ziel-App, während
    /// wir noch auf ein fokussierbares Feld oder freies Secure Input warten:
    /// bricht den automatischen Nachschiebe-Versuch ab (sonst würde später
    /// doppelt eingefügt) und holt die ursprüngliche Zwischenablage zurück,
    /// statt sie dem Nutzer für immer mit dem diktierten Text zu überschreiben.
    private func watchForManualPaste(targetPid: pid_t?, previousClipboard: String?) {
        manualPasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 9, event.modifierFlags.contains(.command) else { return } // ⌘V
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                FlowLog.log("Manuelles ⌘V erkannt — stelle alte Zwischenablage nach dem Einfügen wieder her.")
                self.pendingInsert?.cancel()
                self.pendingInsert = nil
                self.stopManualPasteWatch()
                TextInserter.restoreClipboard(to: previousClipboard)
                self.state = .idle
            }
        }
    }

    private func stopManualPasteWatch() {
        guard let manualPasteMonitor else { return }
        NSEvent.removeMonitor(manualPasteMonitor)
        self.manualPasteMonitor = nil
    }

    private var canStartRecording: Bool {
        switch state {
        case .idle, .error, .waiting, .success: return true
        case .recording, .transcribing: return false
        }
    }

    // MARK: Trello-Todos

    /// Entscheidet, ob das Diktat eine Trello-Karte wird: entweder per
    /// Fn+Ctrl-Chord oder weil das Transkript mit einem Codeword beginnt.
    /// Das Codeword wird im bereinigten Text gesucht, zur Sicherheit auch
    /// im rohen — falls der Cleanup es wegoptimiert hat.
    private static func trelloText(cleaned: String, raw: String, viaChord: Bool) -> String? {
        if let stripped = TodoCodeword.strip(from: cleaned) { return stripped }
        if TodoCodeword.strip(from: raw) != nil { return cleaned }
        return viaChord ? cleaned : nil
    }

    @MainActor
    private func postTrelloCard(text: String) async {
        guard !text.isEmpty else {
            state = .error("Leeres Todo — Karte nicht angelegt.")
            return
        }
        let card = await TodoCardComposer.compose(from: text)
        do {
            try await TrelloClient.createCard(title: card.title, description: card.description)
            FlowLog.log("Trello-Karte angelegt: \(card.title)")
            NSSound(named: "Glass")?.play()
            state = .success("Trello ✓ \(card.title)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let self, case .success = self.state { self.state = .idle }
            }
        } catch {
            NSSound(named: "Basso")?.play()
            state = .error(error.localizedDescription)
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
