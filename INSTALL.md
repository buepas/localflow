# LocalFlow installieren

Diktieren statt tippen: Fn-Taste halten, sprechen, loslassen — der Text landet
in dem Textfeld, in dem du gerade bist. Läuft komplett lokal auf deinem Mac
(Apple Silicon, macOS 15 oder neuer).

## 1. App installieren

1. `LocalFlow-x.x.x.dmg` herunterladen und öffnen.
2. **LocalFlow** in den **Programme**-Ordner ziehen.

## 2. Erster Start (Gatekeeper)

Die App ist nicht bei Apple notarisiert, deshalb blockt macOS den ersten Start:

1. LocalFlow im Programme-Ordner doppelklicken → macOS zeigt eine Warnung. **„Fertig"** klicken (nicht „In den Papierkorb").
2. **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz nach unten scrollen.
3. Bei „LocalFlow wurde blockiert…" auf **„Dennoch öffnen"** klicken und bestätigen.

Das ist nur beim allerersten Start nötig.

## 3. Berechtigungen

Beim ersten Start fragt die App nach zwei Berechtigungen:

1. **Mikrofon** → „Erlauben" klicken.
2. **Bedienungshilfen** (für die Fn-Taste und das automatische Einfügen):
   Systemeinstellungen → Datenschutz & Sicherheit → **Bedienungshilfen** →
   Schalter bei **LocalFlow** aktivieren.

Ob beides passt, siehst du im Menüleisten-Menü der App („Mikrofon ✓ · Bedienungshilfen ✓").

## 4. Fn-Taste freigeben

Systemeinstellungen → **Tastatur** → „Beim Drücken der 🌐-Taste" auf
**„Keine Aktion"** stellen — sonst geht die Apple-eigene Diktierfunktion auf.

## 5. Loslegen

**Fn gedrückt halten, sprechen, loslassen.** Unten am Bildschirm erscheint
dabei eine kleine Anzeige mit Pegelbalken.

- Beim allerersten Diktat lädt die App einmalig das Spracherkennungs-Modell
  (~600 MB) herunter — das dauert je nach Leitung ein paar Minuten. Danach ist
  alles offline.
- Sprache wird automatisch erkannt (Deutsch, Englisch u. v. m.). In den
  Einstellungen (Menüleisten-Symbol) kannst du sie auch fest einstellen.
- **Auto-Edit** (Einstellungen): Wenn du dich beim Sprechen korrigierst
  („um 11 — nee, warte, 12"), wird automatisch die korrigierte Version
  eingefügt. Mit „Apple Intelligence" läuft das komplett auf deinem Mac.

## Problemlösung

- **Nichts passiert beim Fn-Halten** → Bedienungshilfen-Berechtigung prüfen
  (Schritt 3), dann die App einmal neu starten.
- **Wispr Flow oder ein anderes Diktier-Tool läuft parallel** → beenden, die
  Apps streiten sich sonst um die Fn-Taste.
- Log für Fehlersuche: `~/Library/Logs/LocalFlow.log`
