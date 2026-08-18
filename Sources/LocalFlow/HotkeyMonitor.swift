import AppKit

/// Push-to-Talk-Hotkey: Fn (wie Wispr Flow) oder rechte Option-Taste halten.
/// Nutzt globale NSEvent-Monitore — dafür braucht die App die
/// Bedienungshilfen-Berechtigung.
final class HotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Ctrl zusätzlich zum Hotkey gedrückt → dieses Diktat wird eine
    /// Trello-Karte statt einer Texteinfügung.
    var onTrelloChord: (() -> Void)?

    private var monitor: Any?
    private var pressed = false
    private var activated = false
    private var trelloChord = false
    private var activationWorkItem: DispatchWorkItem?

    /// Ein kurzer Tap bleibt für normale Fn-/⌥-Kombinationen reserviert.
    private let activationDelay: TimeInterval = 0.2

    private let fnKeyCode: UInt16 = 63
    private let rightOptionKeyCode: UInt16 = 61

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        pressed = false
        activated = false
        trelloChord = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            handleOtherKeyDown()
            return
        }

        FlowLog.log("flagsChanged keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")

        // Ctrl während des Haltens: Trello-Modus für dieses Diktat merken —
        // bleibt bis zum Loslassen des Hotkeys aktiv.
        if pressed, !trelloChord, event.modifierFlags.contains(.control) {
            trelloChord = true
            if activated { onTrelloChord?() }
        }

        let isDown: Bool
        switch AppSettings.hotkey {
        case .fn:
            guard event.keyCode == fnKeyCode else { return }
            isDown = event.modifierFlags.contains(.function)
        case .rightOption:
            guard event.keyCode == rightOptionKeyCode else { return }
            isDown = event.modifierFlags.contains(.option)
        }

        guard isDown != pressed else { return }
        pressed = isDown

        if isDown {
            // Ctrl kann auch schon vor dem Hotkey gedrückt sein.
            trelloChord = event.modifierFlags.contains(.control)
            scheduleActivation()
        } else {
            activationWorkItem?.cancel()
            activationWorkItem = nil
            if activated {
                activated = false
                onUp?()
            }
        }
    }

    private func scheduleActivation() {
        activationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pressed else { return }
            self.activationWorkItem = nil
            self.activated = true
            self.onDown?()
            if self.trelloChord { self.onTrelloChord?() }
        }
        activationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: workItem)
    }

    /// Sobald während des Haltens eine andere Taste gedrückt wird, handelt es
    /// sich um eine normale Tastenkombination (z. B. Fn-F12), nicht um Diktat.
    private func handleOtherKeyDown() {
        guard pressed else { return }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        if activated {
            activated = false
            onCancel?()
        }
    }
}
