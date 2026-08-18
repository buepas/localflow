import AppKit
import Carbon.HIToolbox
import Darwin

/// Fügt das Transkript ins aktive Textfeld ein: Text in die Zwischenablage,
/// ⌘V simulieren, alte Zwischenablage danach wiederherstellen.
/// (Der AX-Weg über das fokussierte Element wäre sauberer, ist aber v2.)
enum TextInserter {
    enum InsertError: LocalizedError {
        case secureInputActive(blocker: String)
        case secureInputStale
        case noFocusedField

        var errorDescription: String? {
            switch self {
            case .secureInputActive(let blocker):
                return "\(blocker) blockiert Tastatureingaben (Secure Input) — Text liegt in der Zwischenablage, einfach ⌘V drücken."
            case .secureInputStale:
                return "Secure Input hängt fest (App schon beendet). Bildschirm sperren (⌃⌘Q) + entsperren setzt es zurück — Text liegt in der Zwischenablage."
            case .noFocusedField:
                return "Kein Textfeld fokussiert — Text liegt in der Zwischenablage, einfach ⌘V drücken."
            }
        }

        /// Meldung für den Warte-Modus (automatisches Nachschieben läuft).
        var waitingMessage: String {
            switch self {
            case .secureInputActive(let blocker):
                return "\(blocker) blockiert Tastatureingaben (offenes Passwortfeld?) — füge automatisch ein, sobald frei …"
            case .secureInputStale:
                return "Secure Input hängt fest — Menü → „Secure Input freigeben\" (oder ⌃⌘Q). Text wird dann eingefügt."
            case .noFocusedField:
                return "Kein Textfeld fokussiert — füge automatisch ein, sobald eins fokussiert ist …"
            }
        }
    }

    /// Merkt sich pro App, ob der AX-Weg funktioniert — erspart bekannten
    /// Nicht-Könnern (z. B. Terminals) die Aktivierungsversuche samt Wartezeit.
    private static var axVerdictByBundleId: [String: Bool] = [:]

    static func isSecureInputBlocked() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Sperrt den Bildschirm — beim Entsperren setzt das Login-Fenster den
    /// Secure-Input-Zähler zurück (einziger Weg bei verwaisten Blockaden).
    static func lockScreen() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            FlowLog.log("Bildschirmsperre nicht verfügbar (SACLockScreenImmediate fehlt).")
            return
        }
        typealias LockFunction = @convention(c) () -> Void
        unsafeBitCast(symbol, to: LockFunction.self)()
    }

    /// `previousClipboard` ist der Zwischenablage-Inhalt von *vor* diesem
    /// Diktat — bei einem Nachschiebe-Versuch (Secure Input/kein Fokus erst
    /// später freigegeben) liegt zu dem Zeitpunkt bereits der diktierte Text
    /// in der Zwischenablage; ohne den von außen mitgegebenen Originalwert
    /// würde beim erneuten Versuch versehentlich "der diktierte Text" statt
    /// des echten alten Inhalts wiederhergestellt.
    static func insert(_ text: String, restoring previousClipboard: String?) throws {
        FlowLog.log("Einfügen in: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unbekannt")")

        // 1) Direkt ins fokussierte Element schreiben (Accessibility-API,
        //    verifiziert). Tastaturfrei, immun gegen Secure Input.
        if insertViaAccessibility(text) {
            FlowLog.log("Eingefügt via Accessibility-API.")
            return
        }

        // Ohne fokussiertes Element liefe jeder Tastatur-Weg ins Leere —
        // Text bliebe nirgends sichtbar UND die Zwischenablage würde nach
        // 0,4 s trotzdem zurückgesetzt, das Diktat wäre komplett verloren.
        // Stattdessen: Text in der Zwischenablage lassen, Watcher schiebt
        // nach, sobald ein Feld fokussiert wird.
        guard focusedElement() != nil else {
            FlowLog.log("Einfügen blockiert: kein Textfeld fokussiert.")
            setClipboard(text)
            throw InsertError.noFocusedField
        }

        setClipboard(text)

        // 2) Den nativen „Einfügen"-Menüpunkt der Ziel-App auslösen. Das ist
        //    eine Accessibility-Aktion statt eines Tastaturereignisses und
        //    funktioniert deshalb auch bei systemweit aktivem Secure Input.
        if pasteViaMenuAction() {
            FlowLog.log("Eingefügt via nativem Einfügen-Menüpunkt.")
            restoreClipboardLater(previousClipboard)
            return
        }

        // 3) ⌘V direkt an den Zielprozess: läuft durch die
        //    normale Eingabe-Pipeline der App (räumt z. B. Fake-Placeholder
        //    in Web-Composern korrekt weg) und umgeht den systemweiten
        //    Secure-Input-Filter. Wenn das Feld keinen AX-Wert veröffentlicht,
        //    kann der Versand nicht verifiziert werden; dann gilt ein
        //    erfolgreich erzeugtes und versandtes Event als Erfolg.
        if pasteDirectlyToFrontmostApp() {
            FlowLog.log("Eingefügt via Direkt-Paste an die Ziel-App.")
            restoreClipboardLater(previousClipboard)
            return
        }

        // 4) Klassisches ⌘V über das System — nur möglich, wenn kein
        //    Secure Input aktiv ist.
        if !IsSecureEventInputEnabled() {
            postCommandV()
            FlowLog.log("Eingefügt via ⌘V-Fallback.")
            restoreClipboardLater(previousClipboard)
            return
        }

        // 5) Letzter tastaturfreier Versuch: Feldwert direkt setzen
        //    (Placeholder-bewusst, hängt an bestehenden Text an).
        if insertViaAXValue(text) {
            return
        }

        // 6) Blockiert — Text bleibt in der Zwischenablage, der Watcher
        //    schiebt nach, sobald Secure Input freigegeben wird.
        let info = secureInputBlockerInfo()
        FlowLog.log("Einfügen blockiert: Secure Input aktiv (\(info.name ?? "unbekannt"), stale=\(info.stale)).")
        if info.stale {
            throw InsertError.secureInputStale
        }
        throw InsertError.secureInputActive(blocker: info.name ?? "Eine App")
    }

    private static func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Setzt die Zwischenablage nach einem erfolgreichen Einfügen auf den
    /// Stand von *vor* dem Diktat zurück — nur wenn es einen gab.
    private static func restoreClipboardLater(_ previous: String?) {
        restoreClipboard(to: previous)
    }

    /// Öffentlich, damit auch ein manuell erkanntes ⌘V (z. B. während der
    /// Nutzer selbst noch auf ein Feld wartet) die ursprüngliche
    /// Zwischenablage zurückholen kann, nicht nur der automatische Pfad.
    static func restoreClipboard(to previous: String?, after delay: TimeInterval = 0.4) {
        guard let previous else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    /// Schreibt den Text als Ersatz der aktuellen Auswahl direkt ins
    /// systemweit fokussierte UI-Element. Chromium-/Electron-Apps bauen ihren
    /// AX-Baum erst auf Anfrage — dann aktivieren wir ihn (derselbe
    /// Mechanismus wie bei VoiceOver) und versuchen es erneut.
    /// Liefert false, wenn die Ziel-App es nicht kann — dann greift ⌘V.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        if setTextOnFocusedElement(text) { return true }

        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleId = app.bundleIdentifier ?? "unknown"
        if axVerdictByBundleId[bundleId] == false { return false }

        // AX-Baum der Ziel-App aktivieren (Electron: AXManualAccessibility,
        // Chromium: AXEnhancedUserInterface) und kurz auf den Aufbau warten.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        for _ in 0..<4 {
            usleep(120_000)
            if setTextOnFocusedElement(text) {
                FlowLog.log("AX-Baum von \(app.localizedName ?? bundleId) aktiviert — Einfügen klappt jetzt direkt.")
                axVerdictByBundleId[bundleId] = true
                return true
            }
        }
        axVerdictByBundleId[bundleId] = false
        FlowLog.log("\(app.localizedName ?? bundleId) unterstützt AX-Einfügen nicht — künftig direkt ⌘V.")
        return false
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
    }

    private static func focusedElementValue() -> String? {
        guard let element = focusedElement() else { return nil }
        return elementValue(element)
    }

    private static func elementValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private static func setTextOnFocusedElement(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }

        // Niemals in Passwortfelder diktieren.
        if isSecureTextField(element) { return false }

        // 1) An der Cursorposition einfügen (ersetzt die Auswahl).
        //    Chromium meldet hier teils Erfolg, OHNE einzufügen — deshalb
        //    gegen den Feldinhalt verifizieren, wo er lesbar ist.
        var selectedSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedSettable) == .success,
           selectedSettable.boolValue {
            let before = elementValue(element)
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                guard let before, !text.isEmpty else { return true } // nicht verifizierbar → Erfolg annehmen
                if let after = elementValue(element), after != before {
                    return true
                }
                FlowLog.log("AX-SelectedText meldete Erfolg, Feldinhalt unverändert — probiere nächste Stufe.")
            }
        }

        return false
    }

    /// Notnagel: Feldwert direkt setzen. Konservativ — echten Text nie
    /// löschen, nur echte/leere Placeholder ersetzen, sonst anhängen.
    /// (Web-Composer mit Fake-Placeholdern werden bevorzugt über den
    /// Direkt-Paste bedient, der die Eingabe-Pipeline der Seite nutzt.)
    private static func insertViaAXValue(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }

        if isSecureTextField(element) { return false }

        var valueSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
              valueSettable.boolValue else { return false }

        let existing = elementValue(element) ?? ""

        var placeholderRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXPlaceholderValue" as CFString, &placeholderRef)
        let placeholder = placeholderRef as? String
        FlowLog.log("AX-Value-Fallback: vorhanden=\"\(existing.prefix(40))\", placeholder=\"\(placeholder?.prefix(40) ?? "-")\"")

        let isOnlyPlaceholder = existing.isEmpty
            || existing == placeholder
            || existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let newValue = isOnlyPlaceholder ? text : existing + text

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else {
            return false
        }
        // Cursor ans Ende setzen, damit direkt weiterdiktiert werden kann.
        var caret = CFRange(location: (newValue as NSString).length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        FlowLog.log(isOnlyPlaceholder
            ? "Eingefügt via AX-Value (Placeholder ersetzt)."
            : "Eingefügt via AX-Value (an bestehenden Text angehängt).")
        return true
    }

    /// Löst den normalen ⌘V-Menüpunkt der aktiven App über Accessibility aus.
    /// Der Shortcut wird über seine semantischen Menü-Attribute gefunden und
    /// funktioniert daher unabhängig von App und Systemsprache.
    private static func pasteViaMenuAction() -> Bool {
        guard let focused = focusedElement(), !isSecureTextField(focused),
              let app = NSWorkspace.shared.frontmostApplication else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else { return false }

        let menuBar = unsafeDowncast(menuBarRef as AnyObject, to: AXUIElement.self)
        guard let pasteItem = findPlainCommandV(in: menuBar, depth: 0) else { return false }
        return AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success
    }

    /// Findet „⌘V" statt eines lokalisierten Titels wie „Paste"/„Einfügen".
    private static func findPlainCommandV(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 6 else { return nil }

        var commandRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &commandRef) == .success,
           (commandRef as? String)?.lowercased() == "v" {
            var modifiersRef: CFTypeRef?
            let modifiersResult = AXUIElementCopyAttributeValue(
                element,
                kAXMenuItemCmdModifiersAttribute as CFString,
                &modifiersRef
            )
            let modifiers = (modifiersRef as? NSNumber)?.uint32Value ?? 0

            var enabledRef: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(
                element,
                kAXEnabledAttribute as CFString,
                &enabledRef
            )
            let enabled = enabledResult != .success || (enabledRef as? Bool) != false

            // 0 bedeutet Command ohne zusätzliche Shift-/Option-/Control-Taste.
            if modifiersResult != .success || modifiers == 0, enabled {
                return element
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let match = findPlainCommandV(in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    /// ⌘V direkt an den Prozess der aktiven App posten — umgeht den
    /// systemweiten Secure-Input-Filter. Bei einem lesbaren Feld wird der
    /// Erfolg verifiziert; ohne veröffentlichten AX-Wert ist das nicht möglich.
    private static func pasteDirectlyToFrontmostApp() -> Bool {
        guard let focused = focusedElement(), !isSecureTextField(focused),
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let before = elementValue(focused)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(app.processIdentifier)
        keyUp.postToPid(app.processIdentifier)

        guard let before else {
            FlowLog.log("Direkt-Paste versandt; Ziel-App veröffentlicht keinen überprüfbaren AX-Wert.")
            return true
        }

        for _ in 0..<10 {
            usleep(100_000)
            if let after = focusedElementValue(), after != before { return true }
        }
        return false
    }

    /// Ermittelt die App, die Secure Input hält (via IORegistry).
    /// `stale` = der eingetragene Prozess existiert nicht mehr — der Zustand
    /// hängt verwaist fest und lässt sich nur per Sperren/Entsperren lösen.
    private static func secureInputBlockerInfo() -> (name: String?, stale: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-l", "-w", "0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return (nil, false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8),
              let range = output.range(of: "kCGSSessionSecureInputPID\"=([0-9]+)", options: .regularExpression) else {
            return (nil, false)
        }
        let pidString = output[range].split(separator: "=").last.map(String.init) ?? ""
        guard let pid = Int32(pidString) else { return (nil, false) }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (nil, true) // Halter ist tot → verwaister Zustand
        }
        return (app.localizedName, false)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// Ermittelt Kontext über die App, in die diktiert wird — fließt bei den
/// Cloud-Engines in Stil und Schreibweise ein.
enum ContextCapture {
    static func capture() -> DictationContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? "Unknown"
        let bundleId = frontmost?.bundleIdentifier?.lowercased() ?? ""

        let appType: String
        if bundleId.contains("mail") || bundleId.contains("outlook") || bundleId.contains("superhuman") {
            appType = "email"
        } else if bundleId.contains("claude") || bundleId.contains("openai") || bundleId.contains("chatgpt")
                    || bundleId.contains("cursor") || bundleId.contains("perplexity") {
            appType = "ai"
        } else {
            appType = "other"
        }

        let language = AppSettings.language.trimmingCharacters(in: .whitespaces).lowercased()
        return DictationContext(
            appName: appName,
            appType: appType,
            language: language.isEmpty ? [] : [language],
            dictionary: AppSettings.dictionaryTerms,
            userFirstName: AppSettings.userFirstName,
            userLastName: AppSettings.userLastName
        )
    }
}
