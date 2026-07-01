import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let hotkey = HotkeyMonitor()
    private let settingsWindow = SettingsWindowController()
    private let hud = HudController()

    private let stateMenuItem = NSMenuItem(title: "Bereit", action: nil, keyEquivalent: "")
    private let permissionsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var engineMenuItems: [EngineKind: NSMenuItem] = [:]
    private var axPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestPermissions()

        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.render(state: state)
                self?.renderHud(state: state)
            }
        }
        controller.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.pushLevel(level) }
        }

        hotkey.onDown = { [weak self] in self?.controller.hotkeyDown() }
        hotkey.onUp = { [weak self] in self?.controller.hotkeyUp() }
        startHotkeyWhenTrusted()
        preloadLocalModelIfNeeded()
    }

    /// Lädt das lokale Modell schon beim App-Start (statt beim ersten Diktat)
    /// und zeigt den Fortschritt in Menü + HUD.
    private func preloadLocalModelIfNeeded() {
        guard AppSettings.engine == .local else { return }
        LocalParakeetEngine.shared.onProgress = { [weak self] _, text in
            guard let self, self.controller.state == .idle else { return }
            self.stateMenuItem.title = text
            self.hud.show(.loading(text))
        }
        Task { @MainActor [weak self] in
            let loaded = (try? await LocalParakeetEngine.shared.ensureLoaded()) != nil
            FlowLog.log(loaded ? "Lokales Modell bereit." : "Lokales Modell konnte nicht geladen werden.")
            guard let self else { return }
            if self.controller.state == .idle {
                self.render(state: .idle)
                self.hud.hide()
            }
        }
    }

    // MARK: Berechtigungen

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            FlowLog.log("Mikrofon-Zugriff granted=\(granted)")
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        FlowLog.log("Bedienungshilfen trusted=\(AXIsProcessTrustedWithOptions(options))")
    }

    /// Startet den globalen Hotkey-Monitor — und falls die Bedienungshilfen-
    /// Berechtigung noch fehlt, pollt er, bis sie erteilt wurde, und startet
    /// den Monitor dann automatisch neu (sonst wäre ein App-Neustart nötig).
    private func startHotkeyWhenTrusted() {
        if AXIsProcessTrusted() {
            hotkey.start()
            FlowLog.log("Hotkey-Monitor aktiv.")
            return
        }
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.axPollTimer = nil
            self?.hotkey.start()
            FlowLog.log("Bedienungshilfen erteilt — Hotkey-Monitor aktiv.")
            self?.refreshPermissionsStatus()
        }
    }

    private func refreshPermissionsStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        permissionsMenuItem.title = "Mikrofon \(mic ? "✓" : "✗") · Bedienungshilfen \(ax ? "✓" : "✗")"
    }

    // MARK: Menüleiste

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(named: "waveform", description: "LocalFlow")

        let menu = NSMenu()
        menu.delegate = self
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        permissionsMenuItem.isEnabled = false
        menu.addItem(permissionsMenuItem)
        refreshPermissionsStatus()
        menu.addItem(.separator())

        for kind in EngineKind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            engineMenuItems[kind] = item
            menu.addItem(item)
        }
        updateEngineCheckmarks()

        menu.addItem(.separator())

        let preload = NSMenuItem(title: "Lokales Modell vorladen", action: #selector(preloadModel), keyEquivalent: "")
        preload.target = self
        menu.addItem(preload)

        let settings = NSMenuItem(title: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "LocalFlow beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func render(state: DictationController.State) {
        switch state {
        case .idle:
            setIcon(named: "waveform", description: "Bereit")
            stateMenuItem.title = "Bereit — \(AppSettings.hotkey.displayName)"
        case .recording:
            setIcon(named: "record.circle.fill", description: "Aufnahme")
            stateMenuItem.title = "Aufnahme läuft …"
        case .transcribing:
            setIcon(named: "ellipsis.circle", description: "Transkribiere")
            stateMenuItem.title = "Transkribiere (\(AppSettings.engine.displayName)) …"
        case .error(let message):
            setIcon(named: "exclamationmark.triangle", description: "Fehler")
            stateMenuItem.title = "Fehler: \(message)"
        }
    }

    private func renderHud(state: DictationController.State) {
        switch state {
        case .recording:
            hud.show(.recording)
        case .transcribing:
            hud.show(.transcribing)
        case .idle:
            hud.hide()
        case .error(let message):
            hud.show(.error(message))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if case .error = self.controller.state { self.hud.hide() }
            }
        }
    }

    private func setIcon(named symbolName: String, description: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        statusItem.button?.image = image
    }

    private func updateEngineCheckmarks() {
        let current = AppSettings.engine
        for (kind, item) in engineMenuItems {
            item.state = (kind == current) ? .on : .off
        }
    }

    // MARK: Aktionen

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = EngineKind(rawValue: raw) else { return }
        AppSettings.engine = kind
        updateEngineCheckmarks()
        render(state: controller.state)
    }

    @objc private func preloadModel() {
        stateMenuItem.title = "Lade Parakeet-Modell …"
        Task { @MainActor in
            do {
                _ = try await LocalParakeetEngine.shared.ensureLoaded()
                stateMenuItem.title = "Lokales Modell geladen ✓"
            } catch {
                stateMenuItem.title = "Modell-Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshPermissionsStatus()
    }
}
