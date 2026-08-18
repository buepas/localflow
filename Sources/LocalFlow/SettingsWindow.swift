import AppKit
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @AppStorage("engine") private var engine = EngineKind.local.rawValue
    @AppStorage("hotkey") private var hotkey = HotkeyKind.fn.rawValue
    @AppStorage("micDeviceUID") private var micDeviceUID = ""

    private let inputDevices: [(name: String, uid: String)] = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
    ).devices.map { ($0.localizedName, $0.uniqueID) }
    @AppStorage("language") private var language = ""
    @AppStorage("dictionary") private var dictionary = ""
    @AppStorage("userFirstName") private var firstName = ""
    @AppStorage("userLastName") private var lastName = ""
    @AppStorage("wisprApiKey") private var wisprApiKey = ""
    @AppStorage("elevenLabsApiKey") private var elevenLabsApiKey = ""
    @AppStorage("elevenLabsRemoveFillers") private var removeFillers = true
    @AppStorage("cleanupMode") private var cleanupMode = CleanupMode.off.rawValue
    @AppStorage("saveTranscripts") private var saveTranscripts = true
    @AppStorage("anthropicApiKey") private var anthropicApiKey = ""
    @AppStorage("claudeModel") private var claudeModel = "claude-opus-4-8"
    @AppStorage("trelloApiKey") private var trelloApiKey = ""
    @AppStorage("trelloToken") private var trelloToken = ""
    @AppStorage("trelloListId") private var trelloListId = ""
    @AppStorage("trelloListName") private var trelloListName = ""
    @AppStorage("trelloCodewords") private var trelloCodewords = "todo, trello"
    @AppStorage("trelloSmartSplit") private var trelloSmartSplit = true
    @State private var trelloLists: [TrelloList] = []
    @State private var trelloStatus = ""

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
                Picker("Mikrofon", selection: $micDeviceUID) {
                    Text("Automatisch (integriertes Mikrofon)").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .help("Bluetooth-Mikros (AirPods) brauchen 1–2 s Anlaufzeit — der Anfang des Diktats geht dabei verloren. Empfohlen: Automatisch oder ein kabelgebundenes Mikrofon.")
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

            Section("Trello-Todos") {
                SecureField("API-Key", text: $trelloApiKey)
                SecureField("Token", text: $trelloToken)
                Text("Key unter trello.com/power-ups/admin erstellen (Power-Up anlegen → API-Key), Token über den \"Token\"-Link daneben generieren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Boards & Listen laden") { loadTrelloLists() }
                    Text(trelloStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !trelloLists.isEmpty {
                    Picker("Ziel-Liste", selection: $trelloListId) {
                        Text("Bitte wählen").tag("")
                        ForEach(trelloLists) { list in
                            Text("\(list.boardName) → \(list.name)").tag(list.id)
                        }
                    }
                    .onChange(of: trelloListId) { _, newValue in
                        if let list = trelloLists.first(where: { $0.id == newValue }) {
                            trelloListName = "\(list.boardName) → \(list.name)"
                        }
                    }
                } else if !trelloListName.isEmpty {
                    LabeledContent("Ziel-Liste", value: trelloListName)
                }
                TextField("Codewörter (kommagetrennt)", text: $trelloCodewords)
                    .help("Beginnt ein Diktat mit einem dieser Wörter, wird daraus eine Trello-Karte — z. B. \"Todo Angebot für Müller nachfassen\". Erkennung ist tolerant gegen Tippfehler der Engine.")
                Toggle("Titel + Beschreibung per Apple Intelligence", isOn: $trelloSmartSplit)
                Text("Codeword am Diktat-Anfang oder Hotkey+Ctrl halten → Karte landet oben in der Ziel-Liste statt als Text im aktiven Fenster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transkript-Archiv") {
                Toggle("Diktate im Volltext lokal speichern", isOn: $saveTranscripts)
                Text("Jedes Diktat wird als JSON-Zeile an transcripts.jsonl im Application-Support-Ordner angehängt (Text, Roh-Transkript, App, Engine, Dauer). Bleibt komplett auf diesem Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)
    }

    private func loadTrelloLists() {
        trelloStatus = "Lade …"
        Task { @MainActor in
            do {
                trelloLists = try await TrelloClient.fetchLists()
                trelloStatus = "\(trelloLists.count) Listen geladen"
            } catch {
                trelloStatus = error.localizedDescription
            }
        }
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
