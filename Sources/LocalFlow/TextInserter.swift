import AppKit
import Carbon.HIToolbox

/// Fügt das Transkript ins aktive Textfeld ein: Text in die Zwischenablage,
/// ⌘V simulieren, alte Zwischenablage danach wiederherstellen.
/// (Der AX-Weg über das fokussierte Element wäre sauberer, ist aber v2.)
enum TextInserter {
    enum InsertError: LocalizedError {
        case secureInputActive(blocker: String)
        case secureInputStale

        var errorDescription: String? {
            switch self {
            case .secureInputActive(let blocker):
                return "\(blocker) blockiert Tastatureingaben (Secure Input) — Text liegt in der Zwischenablage, einfach ⌘V drücken."
            case .secureInputStale:
                return "Secure Input hängt fest (App schon beendet). Bildschirm sperren (⌃⌘Q) + entsperren setzt es zurück — Text liegt in der Zwischenablage."
            }
        }
    }

    /// Merkt sich pro App, ob der AX-Weg funktioniert — erspart bekannten
    /// Nicht-Könnern (z. B. Terminals) die Aktivierungsversuche samt Wartezeit.
    private static var axVerdictByBundleId: [String: Bool] = [:]

    static func insert(_ text: String) throws {
        // Bevorzugt: direkt ins fokussierte Element schreiben (Accessibility-API).
        // Braucht keine simulierten Tastendrücke und funktioniert daher auch,
        // während irgendeine App Secure Input hält.
        if insertViaAccessibility(text) {
            FlowLog.log("Eingefügt via Accessibility-API.")
            return
        }

        let pasteboard = NSPasteboard.general

        // Fallback ⌘V: Secure Input (Passwortfeld, Terminal mit "Secure
        // Keyboard Entry", offene Systemeinstellungen …) verwirft simulierte
        // Tastendrücke systemweit. Dann lassen wir den Text in der
        // Zwischenablage statt stumm zu scheitern.
        guard !IsSecureEventInputEnabled() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let info = secureInputBlockerInfo()
            FlowLog.log("Einfügen blockiert: Secure Input aktiv (\(info.name ?? "unbekannt"), stale=\(info.stale)).")
            if info.stale {
                throw InsertError.secureInputStale
            }
            throw InsertError.secureInputActive(blocker: info.name ?? "Eine App")
        }

        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()
        FlowLog.log("Eingefügt via ⌘V-Fallback.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
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

    private static func setTextOnFocusedElement(_ text: String) -> Bool {
        var focused: CFTypeRef?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // Niemals in Passwortfelder diktieren.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXSecureTextField" { return false }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
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
