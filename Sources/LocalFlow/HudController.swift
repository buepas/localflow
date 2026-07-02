import AppKit
import SwiftUI

/// Schwebende Feedback-Pille am unteren Bildschirmrand (wie beim Original):
/// Aufnahme mit Live-Pegel, Transkriptions-Spinner, Fehlermeldung.
/// Alle Aufrufe müssen vom Main-Thread kommen.
final class HudController {
    enum Mode {
        case recording
        case transcribing
        case loading(String)
        case error(String)
    }

    private let model = HudModel()
    private var panel: NSPanel?

    func show(_ mode: Mode) {
        model.mode = mode
        if case .recording = mode {
            model.levels = Array(repeating: 0.03, count: HudModel.barCount)
        }
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func pushLevel(_ level: Float) {
        guard case .recording = model.mode else { return }
        model.levels.removeFirst()
        model.levels.append(level)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HudView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 28
        ))
    }
}

final class HudModel: ObservableObject {
    static let barCount = 24
    @Published var mode: HudController.Mode = .recording
    @Published var levels: [Float] = Array(repeating: 0.03, count: barCount)
}

struct HudView: View {
    @ObservedObject var model: HudModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                HStack(spacing: 3) {
                    ForEach(model.levels.indices, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.9))
                            .frame(width: 3, height: 4 + CGFloat(min(1, model.levels[index])) * 22)
                    }
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transkribiere …")
                    .foregroundStyle(.white)
            case .loading(let message):
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(message)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 360)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 18)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.82)))
        .animation(.easeOut(duration: 0.08), value: model.levels)
        .frame(width: 420, height: 72)
    }
}
