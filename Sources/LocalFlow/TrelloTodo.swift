import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Trello-REST-Client (API-Key + Token, kein SDK nötig)

enum TrelloError: LocalizedError {
    case missingCredentials
    case missingList
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Trello: API-Key/Token fehlen (Einstellungen)."
        case .missingList: return "Trello: keine Ziel-Liste gewählt (Einstellungen)."
        case .server(let message): return "Trello: \(message)"
        }
    }
}

struct TrelloList: Identifiable {
    let id: String
    let name: String
    let boardName: String
}

enum TrelloClient {
    static func createCard(title: String, description: String) async throws {
        let key = AppSettings.trelloApiKey
        let token = AppSettings.trelloToken
        guard !key.isEmpty, !token.isEmpty else { throw TrelloError.missingCredentials }
        guard !AppSettings.trelloListId.isEmpty else { throw TrelloError.missingList }

        var components = URLComponents(string: "https://api.trello.com/1/cards")!
        components.queryItems = [
            URLQueryItem(name: "idList", value: AppSettings.trelloListId),
            URLQueryItem(name: "name", value: title),
            URLQueryItem(name: "desc", value: description),
            URLQueryItem(name: "pos", value: "top"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "token", value: token),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        try await perform(request)
    }

    /// Alle offenen Boards samt Listen — für den Ziel-Listen-Picker
    /// in den Einstellungen.
    static func fetchLists() async throws -> [TrelloList] {
        let key = AppSettings.trelloApiKey
        let token = AppSettings.trelloToken
        guard !key.isEmpty, !token.isEmpty else { throw TrelloError.missingCredentials }

        var components = URLComponents(string: "https://api.trello.com/1/members/me/boards")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "open"),
            URLQueryItem(name: "fields", value: "name"),
            URLQueryItem(name: "lists", value: "open"),
            URLQueryItem(name: "list_fields", value: "name"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "token", value: token),
        ]
        let data = try await perform(URLRequest(url: components.url!))

        guard let boards = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TrelloError.server("unerwartete Antwortstruktur.")
        }
        return boards.flatMap { board -> [TrelloList] in
            let boardName = board["name"] as? String ?? "?"
            let lists = board["lists"] as? [[String: Any]] ?? []
            return lists.compactMap { list in
                guard let id = list["id"] as? String, let name = list["name"] as? String else { return nil }
                return TrelloList(id: id, name: name, boardName: boardName)
            }
        }
    }

    @discardableResult
    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await withTimeout(seconds: 20) {
            try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw TrelloError.server("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(detail.prefix(200))")
        }
        return data
    }
}

// MARK: - Codeword-Erkennung

enum TodoCodeword {
    /// Beginnt das Transkript mit einem der konfigurierten Codewörter,
    /// kommt der Text ohne Codeword zurück, sonst nil. Der Vergleich ist
    /// unscharf — Groß/Klein, Satzzeichen, Leerzeichen/Bindestriche
    /// ("To-do:", "To do") und ab 5 Buchstaben ein Tippfehler ("Trelo"),
    /// weil die Engines das Codeword nicht immer sauber treffen.
    static func strip(from text: String) -> String? {
        let codewords = AppSettings.trelloCodewordList.map(normalize).filter { !$0.isEmpty }
        guard !codewords.isEmpty else { return nil }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        for count in 1...2 where words.count >= count {
            let candidate = normalize(words.prefix(count).joined(separator: " "))
            guard !candidate.isEmpty else { continue }
            for codeword in codewords {
                let tolerance = codeword.count >= 5 ? 1 : 0
                guard levenshtein(candidate, codeword) <= tolerance else { continue }
                let rest = words.dropFirst(count).joined(separator: " ")
                return String(rest.drop { ":,-–.".contains($0) || $0 == " " })
            }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? previous : min(previous, row[j], row[j + 1]) + 1
                previous = row[j + 1]
                row[j + 1] = cost
            }
        }
        return row[b.count]
    }
}

// MARK: - Karten-Composer (Apple Intelligence, Fallback: Heuristik)

struct TodoCard {
    let title: String
    let description: String
}

enum TodoCardComposer {
    static func compose(from text: String) async -> TodoCard {
        if AppSettings.trelloSmartSplit, let card = await composeOnDevice(text) {
            return card
        }
        return fallback(text)
    }

    /// Titel + Beschreibung per on-device Foundation Model (macOS 26,
    /// Apple Intelligence). Liefert nil, wenn nicht verfügbar oder
    /// fehlgeschlagen — dann greift die Heuristik.
    private static func composeOnDevice(_ text: String) async -> TodoCard? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        do {
            // @Generable-Structured-Output baut unter SwiftPM/CLT nicht
            // (Macro-Plugin fehlt außerhalb von Xcode) — daher festes
            // Textformat: Zeile 1 Titel, Rest Beschreibung.
            let session = LanguageModelSession(instructions: """
                Du machst aus einem diktierten Todo eine Trello-Karte. \
                Antworte in der Sprache des Diktats und exakt in diesem Format: \
                erste Zeile ein kurzer, prägnanter Aufgaben-Titel (max. 10 Wörter, \
                kein Punkt am Ende), danach optional die Details (Kontext, Fristen) \
                als Beschreibung. Nichts hinzuerfinden, nichts beantworten. \
                Deckt der Titel schon alles ab, bleibt die Beschreibung leer.
                """)
            let response = try await session.respond(to: text)
            let lines = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let details = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TodoCard(title: title, description: details)
        } catch {
            FlowLog.log("Apple-Intelligence-Karte fehlgeschlagen, nutze Heuristik: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Kurze Diktate 1:1 als Titel; lange bekommen den ersten Satz als
    /// Titel und den Volltext als Beschreibung.
    private static func fallback(_ text: String) -> TodoCard {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return TodoCard(title: trimmed, description: "") }
        let firstSentence = trimmed
            .split(whereSeparator: { ".!?".contains($0) })
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? trimmed
        return TodoCard(title: String(firstSentence.prefix(100)), description: trimmed)
    }
}
