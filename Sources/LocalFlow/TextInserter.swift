import AppKit
import Carbon.HIToolbox

/// Fügt das Transkript ins aktive Textfeld ein: Text in die Zwischenablage,
/// ⌘V simulieren, alte Zwischenablage danach wiederherstellen.
/// (Der AX-Weg über das fokussierte Element wäre sauberer, ist aber v2.)
enum TextInserter {
    enum InsertError: LocalizedError {
        case secureInputActive(blocker: String)

        var errorDescription: String? {
            switch self {
            case .secureInputActive(let blocker):
                return "\(blocker) blockiert Tastatureingaben (Secure Input) — Text liegt in der Zwischenablage, einfach ⌘V drücken."
            }
        }
    }

    static func insert(_ text: String) throws {
        let pasteboard = NSPasteboard.general

        // Secure Input (z. B. fokussiertes Passwortfeld, Terminal mit "Secure
        // Keyboard Entry") verwirft simulierte Tastendrücke systemweit. Dann
        // lassen wir den Text in der Zwischenablage statt stumm zu scheitern.
        guard !IsSecureEventInputEnabled() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let blocker = secureInputBlockerName() ?? "Eine App"
            FlowLog.log("Einfügen blockiert: Secure Input aktiv (\(blocker)).")
            throw InsertError.secureInputActive(blocker: blocker)
        }

        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Ermittelt die App, die Secure Input hält (via IORegistry).
    private static func secureInputBlockerName() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-l", "-w", "0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8),
              let range = output.range(of: "kCGSSessionSecureInputPID\"=([0-9]+)", options: .regularExpression) else {
            return nil
        }
        let pidString = output[range].split(separator: "=").last.map(String.init) ?? ""
        guard let pid = Int32(pidString),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName
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

        let language = AppSettings.language.trimmingCharacters(in: .whitespaces)
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
