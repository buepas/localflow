import AppKit

/// Push-to-Talk-Hotkey: Fn (wie Wispr Flow) oder rechte Option-Taste halten.
/// Nutzt globale NSEvent-Monitore — dafür braucht die App die
/// Bedienungshilfen-Berechtigung.
final class HotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var monitor: Any?
    private var pressed = false

    private let fnKeyCode: UInt16 = 63
    private let rightOptionKeyCode: UInt16 = 61

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        pressed = false
    }

    private func handle(_ event: NSEvent) {
        FlowLog.log("flagsChanged keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
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
        DispatchQueue.main.async { [weak self] in
            if isDown { self?.onDown?() } else { self?.onUp?() }
        }
    }
}
