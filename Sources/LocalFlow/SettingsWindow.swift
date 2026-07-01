import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("engine") private var engine = EngineKind.local.rawValue
    @AppStorage("hotkey") private var hotkey = HotkeyKind.fn.rawValue
    @AppStorage("language") private var language = ""
    @AppStorage("dictionary") private var dictionary = ""
    @AppStorage("userFirstName") private var firstName = ""
    @AppStorage("userLastName") private var lastName = ""
    @AppStorage("wisprApiKey") private var wisprApiKey = ""
    @AppStorage("elevenLabsApiKey") private var elevenLabsApiKey = ""
    @AppStorage("elevenLabsRemoveFillers") private var removeFillers = true
    @AppStorage("cleanupMode") private var cleanupMode = CleanupMode.off.rawValue
    @AppStorage("anthropicApiKey") private var anthropicApiKey = ""
    @AppStorage("claudeModel") private var claudeModel = "claude-opus-4-8"

    var body: some View {
        Form {
            Section("Allgemein") {
                Picker("Engine", selection: $engine) {
                    ForEach(EngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                Picker("Hotkey (halten)", selection: $hotkey) {
                    ForEach(HotkeyKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                TextField("Sprache (ISO-Code, leer = Auto)", text: $language)
                    .help("z. B. de oder en — leer lassen für automatische Erkennung")
            }

            Section("Personalisierung") {
                TextField("Vorname", text: $firstName)
                TextField("Nachname", text: $lastName)
                TextField("Wörterbuch (kommagetrennt)", text: $dictionary)
                    .help("Eigennamen und Fachbegriffe, z. B. Evalent, Supabase, Wispr")
            }

            Section("Wispr Flow API") {
                SecureField("API-Key", text: $wisprApiKey)
                Text("Key im Developer-Dashboard erstellen: platform.wisprflow.ai")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ElevenLabs") {
                SecureField("API-Key", text: $elevenLabsApiKey)
                Toggle("Füllwörter entfernen (scribe_v2)", isOn: $removeFillers)
            }

            Section("Auto-Edit (Selbstkorrekturen auflösen)") {
                Picker("Nachbearbeitung", selection: $cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text("Löst \"um 11 Uhr — nee, warte, 12\" zu \"um 12 Uhr\" auf. Gilt für Lokal und ElevenLabs; die Wispr-API macht das bereits selbst.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if cleanupMode == CleanupMode.claude.rawValue {
                    SecureField("Anthropic API-Key", text: $anthropicApiKey)
                    TextField("Modell", text: $claudeModel)
                        .help("Standard: claude-opus-4-8 — für weniger Latenz z. B. claude-haiku-4-5")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }
}

/// Hostet die SwiftUI-Einstellungen in einem normalen Fenster —
/// die App selbst ist nur ein Menüleisten-Accessory.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "LocalFlow Einstellungen"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
