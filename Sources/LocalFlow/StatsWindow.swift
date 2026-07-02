import AppKit
import SwiftUI

struct StatsView: View {
    let store = StatsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deine Diktier-Statistiken")
                .font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(value: "\(store.totalWords)", label: "Wörter gesamt")
                statCard(value: String(format: "%.0f", store.averageWPM), label: "Ø Wörter/Minute")
                statCard(value: formattedMinutes(store.timeSavedMinutes), label: "Zeit gespart*")
                statCard(value: "\(store.totalDictations)", label: "Diktate")
                statCard(value: formattedMinutes(store.totalSpeakingSeconds / 60), label: "Sprechzeit")
                statCard(value: "\(store.streakDays) Tage", label: "Serie")
            }

            statCard(value: "\(store.todayWords)", label: "Wörter heute")
                .frame(maxWidth: .infinity)

            if !store.topApps.isEmpty {
                Text("Top-Apps")
                    .font(.headline)
                ForEach(store.topApps, id: \.name) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text("\(app.words) Wörter")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }

            Text("*verglichen mit Tippen bei 40 Wörtern/Minute")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func formattedMinutes(_ minutes: Double) -> String {
        if minutes >= 60 {
            return String(format: "%.1f h", minutes / 60)
        }
        return String(format: "%.0f min", minutes)
    }
}

final class StatsWindowController {
    private var window: NSWindow?

    func show() {
        // Fenster jedes Mal neu aufbauen, damit die Zahlen aktuell sind.
        let hosting = NSHostingController(rootView: StatsView())
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "LocalFlow Statistiken"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
