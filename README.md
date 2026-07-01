# LocalFlow

Ein Wispr-Flow-Nachbau für macOS (Apple Silicon): systemweites Push-to-Talk-Diktat
mit drei umschaltbaren Transkriptions-Engines:

| Engine | Typ | Anmerkungen |
|---|---|---|
| **Lokal (Parakeet TDT v3)** | offline, on-device | via [FluidAudio](https://github.com/FluidInference/FluidAudio)/CoreML auf der Neural Engine, 25 Sprachen, kein API-Key nötig |
| **Wispr Flow API** | Cloud, Streaming | offizielle API (`platform-api.wisprflow.ai`), WebSocket, liefert bereits bereinigten Text (Auto-Edits) |
| **ElevenLabs Scribe v2** | Cloud, Batch | REST-Upload, optional `no_verbatim` (Füllwörter entfernen) |

## Bauen & Starten

Benötigt nur die Xcode Command Line Tools (kein Xcode):

```bash
./build.sh
open build/LocalFlow.app
```

## Einrichtung (einmalig)

1. **Mikrofon**: Berechtigungsdialog beim ersten Diktat bestätigen.
2. **Bedienungshilfen**: Systemeinstellungen → Datenschutz & Sicherheit →
   Bedienungshilfen → LocalFlow aktivieren (nötig für den globalen Hotkey und ⌘V-Einfügen).
3. **Fn-Taste freigeben**: Systemeinstellungen → Tastatur → „Beim Drücken der
   Fn-Taste" auf **„Keine Aktion"** stellen (sonst öffnet macOS die eigene Diktierfunktion).
   Alternativ in den LocalFlow-Einstellungen auf „Rechte ⌥-Taste" wechseln.
4. **API-Keys** (nur für die Cloud-Engines): Menüleisten-Symbol → Einstellungen.
   - Wispr Flow: Key im [Developer-Dashboard](https://api-docs.wisprflow.ai/introduction) erstellen
   - ElevenLabs: Key unter elevenlabs.io → Profil → API Keys

## Benutzung

Hotkey (Standard: **Fn**) gedrückt halten, sprechen, loslassen — der Text landet
im gerade fokussierten Textfeld. Engine-Wechsel direkt im Menüleisten-Menü.

Beim ersten lokalen Diktat lädt FluidAudio die Parakeet-Modelle (~1 GB) von
Hugging Face herunter („Lokales Modell vorladen" im Menü stößt das manuell an).

## Architektur

```
Sources/LocalFlow/
├── main.swift               NSApplication-Bootstrap (Menüleisten-Accessory)
├── AppDelegate.swift        Statusitem, Menü, Berechtigungen
├── HotkeyMonitor.swift      Globaler Fn-/⌥-Monitor (Push-to-Talk)
├── DictationController.swift  Ablauf: Aufnahme → Session → Einfügen
├── AudioRecorder.swift      AVAudioEngine → 16 kHz mono Int16, 50-ms-Pakete + WAV-Encoder
├── TranscriptionEngine.swift  Engine-/Session-Protokolle, Kontext-Modell
├── LocalParakeetEngine.swift  FluidAudio Parakeet TDT v3 (Batch, offline)
├── WisprFlowEngine.swift    Wispr-WebSocket: auth → append(Pakete) → commit → Text
├── ElevenLabsEngine.swift   Scribe v2 REST (multipart, keyterms, no_verbatim)
├── TextInserter.swift       Zwischenablage + simuliertes ⌘V, Kontext-Erfassung
├── AppSettings.swift        UserDefaults-Settings
└── SettingsWindow.swift     SwiftUI-Einstellungsfenster
```

Alle Engines bekommen dasselbe Audioformat (16 kHz mono Int16). Streaming-Engines
(Wispr) erhalten die 50-ms-Pakete live während der Aufnahme; Batch-Engines sammeln
und transkribieren beim Loslassen des Hotkeys.

## Auto-Edit (Selbstkorrekturen)

Wisprs Kern-Feature — "um 11 Uhr, nee warte, 12 Uhr" wird zu "um 12 Uhr" — gibt es
für die Lokal- und ElevenLabs-Engine als LLM-Nachbearbeitung (Einstellungen → Auto-Edit):

- **Apple Intelligence** — on-device via FoundationModels (macOS 26+, Apple
  Intelligence muss in den Systemeinstellungen aktiviert sein). Kein API-Key, privat.
- **Claude API** — höhere Qualität, braucht einen Anthropic-API-Key.
  Standard-Modell `claude-opus-4-8`; für weniger Latenz `claude-haiku-4-5` eintragen.

Schlägt der Cleanup fehl, wird das rohe Transkript eingefügt (Details im Log).

## Hinweis zu Rebuilds

Die App ist ad-hoc-signiert. Nach jedem `./build.sh` muss die
Bedienungshilfen-Freigabe erneuert werden — zuverlässig per:

```bash
tccutil reset Accessibility ai.evalent.localflow
open build/LocalFlow.app   # dann in den Systemeinstellungen neu erteilen
```

## Bekannte MVP-Grenzen (v2-Kandidaten)

- Einfügen per ⌘V statt Accessibility-API; `textbox_contents`-Kontext wird noch
  nicht an Wispr übergeben.
- API-Keys liegen in den UserDefaults, nicht in der Keychain.
- Keine Snippets, kein lernendes Wörterbuch, kein Sync.
- Max. ~6 min pro Diktat (Wispr-API-Limit) wird nicht erzwungen.
