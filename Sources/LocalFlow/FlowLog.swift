import Foundation

/// Simpler Datei-Logger (~/Library/Logs/LocalFlow.log) — das Unified Log ist
/// für Ad-hoc-Diagnose von außen unzuverlässig auslesbar.
enum FlowLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalFlow.log")

    private static let queue = DispatchQueue(label: "ai.evalent.localflow.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        NSLog("LocalFlow: %@", message)
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
