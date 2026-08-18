import Foundation

enum EngineKind: String, CaseIterable, Identifiable {
    case local
    case wispr
    case elevenlabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Lokal (Parakeet v3)"
        case .wispr: return "Wispr Flow API"
        case .elevenlabs: return "ElevenLabs Scribe"
        }
    }
}

enum HotkeyKind: String, CaseIterable, Identifiable {
    case fn
    case rightOption

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn-Taste halten"
        case .rightOption: return "Rechte ⌥-Taste halten"
        }
    }
}

/// UserDefaults-backed settings. API-Keys liegen hier bewusst simpel in den
/// Defaults (MVP) — für ein Release gehören sie in die Keychain.
struct AppSettings {
    static let defaults = UserDefaults.standard

    static var engine: EngineKind {
        get { EngineKind(rawValue: defaults.string(forKey: "engine") ?? "") ?? .local }
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }

    static var hotkey: HotkeyKind {
        get { HotkeyKind(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    /// UID des Aufnahmegeräts; leer = automatisch (integriertes Mikrofon
    /// bevorzugt — Bluetooth-Mikros brauchen 1–2 s Anlaufzeit, in der der
    /// Diktat-Anfang verloren geht).
    static var micDeviceUID: String {
        get { defaults.string(forKey: "micDeviceUID") ?? "" }
        set { defaults.set(newValue, forKey: "micDeviceUID") }
    }

    /// ISO-639-1-Code, leer = automatische Erkennung.
    static var language: String {
        get { defaults.string(forKey: "language") ?? "" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Kommagetrennte Liste eigener Begriffe (Namen, Fachwörter).
    static var dictionary: String {
        get { defaults.string(forKey: "dictionary") ?? "" }
        set { defaults.set(newValue, forKey: "dictionary") }
    }

    static var dictionaryTerms: [String] {
        dictionary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var userFirstName: String {
        get { defaults.string(forKey: "userFirstName") ?? "" }
        set { defaults.set(newValue, forKey: "userFirstName") }
    }

    static var userLastName: String {
        get { defaults.string(forKey: "userLastName") ?? "" }
        set { defaults.set(newValue, forKey: "userLastName") }
    }

    static var wisprApiKey: String {
        get { defaults.string(forKey: "wisprApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "wisprApiKey") }
    }

    static var elevenLabsApiKey: String {
        get { defaults.string(forKey: "elevenLabsApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "elevenLabsApiKey") }
    }

    /// ElevenLabs scribe_v2: Füllwörter entfernen (ähnlich Wispr Auto-Edit).
    static var elevenLabsRemoveFillers: Bool {
        get { defaults.object(forKey: "elevenLabsRemoveFillers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "elevenLabsRemoveFillers") }
    }

    /// Diktate im Volltext lokal archivieren (transcripts.jsonl) —
    /// eigener Text-Korpus für spätere Auswertung.
    static var saveTranscripts: Bool {
        get { defaults.object(forKey: "saveTranscripts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveTranscripts") }
    }

    /// Auto-Edit-Nachbearbeitung für Engines mit rohem Transkript
    /// (lokal, ElevenLabs). Die Wispr-API bereinigt bereits serverseitig.
    static var cleanupMode: CleanupMode {
        get { CleanupMode(rawValue: defaults.string(forKey: "cleanupMode") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "cleanupMode") }
    }

    static var anthropicApiKey: String {
        get { defaults.string(forKey: "anthropicApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "anthropicApiKey") }
    }

    // MARK: Trello-Todos

    static var trelloApiKey: String {
        get { defaults.string(forKey: "trelloApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "trelloApiKey") }
    }

    static var trelloToken: String {
        get { defaults.string(forKey: "trelloToken") ?? "" }
        set { defaults.set(newValue, forKey: "trelloToken") }
    }

    static var trelloListId: String {
        get { defaults.string(forKey: "trelloListId") ?? "" }
        set { defaults.set(newValue, forKey: "trelloListId") }
    }

    /// Anzeigename der gewählten Liste ("Board → Liste") — nur fürs UI.
    static var trelloListName: String {
        get { defaults.string(forKey: "trelloListName") ?? "" }
        set { defaults.set(newValue, forKey: "trelloListName") }
    }

    /// Kommagetrennte Codewörter am Diktat-Anfang, die das Diktat als
    /// Trello-Karte statt als Texteinfügung enden lassen.
    static var trelloCodewords: String {
        get { defaults.string(forKey: "trelloCodewords") ?? "todo, trello" }
        set { defaults.set(newValue, forKey: "trelloCodewords") }
    }

    static var trelloCodewordList: [String] {
        trelloCodewords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Titel + Beschreibung on-device per Apple Intelligence erzeugen;
    /// aus = Transkript 1:1 als Kartentitel.
    static var trelloSmartSplit: Bool {
        get { defaults.object(forKey: "trelloSmartSplit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "trelloSmartSplit") }
    }

    static var claudeModel: String {
        get {
            let value = defaults.string(forKey: "claudeModel") ?? ""
            return value.isEmpty ? "claude-opus-4-8" : value
        }
        set { defaults.set(newValue, forKey: "claudeModel") }
    }
}
