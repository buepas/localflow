import Foundation

/// Diktier-Statistiken, lokal als JSON unter
/// ~/Library/Application Support/LocalFlow/stats.json — pro Tag aggregiert,
/// es werden keine Inhalte gespeichert, nur Zählwerte.
struct DayStats: Codable {
    var date: String // "2026-07-02"
    var words: Int = 0
    var characters: Int = 0
    var speakingSeconds: Double = 0
    var dictations: Int = 0
    var appWords: [String: Int] = [:]
}

final class StatsStore {
    static let shared = StatsStore()

    private(set) var days: [DayStats] = []

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([DayStats].self, from: data) {
            days = decoded
        }
    }

    func record(text: String, duration: TimeInterval, appName: String) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return }
        let today = Self.dayFormatter.string(from: Date())

        var day = days.first(where: { $0.date == today }) ?? DayStats(date: today)
        day.words += words
        day.characters += text.count
        day.speakingSeconds += duration
        day.dictations += 1
        day.appWords[appName, default: 0] += words

        days.removeAll { $0.date == today }
        days.append(day)
        days.sort { $0.date < $1.date }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: Self.fileURL)
        }
    }

    // MARK: Auswertungen

    var totalWords: Int { days.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { days.reduce(0) { $0 + $1.dictations } }
    var totalSpeakingSeconds: Double { days.reduce(0) { $0 + $1.speakingSeconds } }

    var todayWords: Int {
        let today = Self.dayFormatter.string(from: Date())
        return days.first(where: { $0.date == today })?.words ?? 0
    }

    /// Durchschnittliches Diktier-Tempo in Wörtern pro Minute.
    var averageWPM: Double {
        guard totalSpeakingSeconds > 5 else { return 0 }
        return Double(totalWords) / (totalSpeakingSeconds / 60)
    }

    /// Gesparte Zeit gegenüber Tippen (Referenz: 40 WPM) in Minuten.
    var timeSavedMinutes: Double {
        let typingMinutes = Double(totalWords) / 40.0
        let speakingMinutes = totalSpeakingSeconds / 60
        return max(0, typingMinutes - speakingMinutes)
    }

    /// Anzahl aufeinanderfolgender Tage mit mindestens einem Diktat,
    /// gezählt bis heute (bzw. gestern, wenn heute noch nichts diktiert wurde).
    var streakDays: Int {
        let dates = Set(days.filter { $0.dictations > 0 }.map(\.date))
        guard !dates.isEmpty else { return 0 }
        var cursor = Date()
        if !dates.contains(Self.dayFormatter.string(from: cursor)) {
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        var streak = 0
        while dates.contains(Self.dayFormatter.string(from: cursor)) {
            streak += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    var topApps: [(name: String, words: Int)] {
        var totals: [String: Int] = [:]
        for day in days {
            for (app, words) in day.appWords {
                totals[app, default: 0] += words
            }
        }
        return totals.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
}
