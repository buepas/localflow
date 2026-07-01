import FluidAudio
import Foundation

/// Lokale Transkription mit NVIDIA Parakeet TDT v3 (25 Sprachen) über
/// FluidAudio/CoreML — läuft komplett offline auf der Neural Engine.
/// Die Modelle (~1 GB) werden beim ersten Start von Hugging Face geladen.
final class LocalParakeetEngine: TranscriptionEngine {
    static let shared = LocalParakeetEngine()

    let kind: EngineKind = .local

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    /// Ladefortschritt 0…1 und Statustext — für Menü und HUD.
    private(set) var loadProgress: Double = 0
    var onProgress: ((Double, String) -> Void)?
    var isLoaded: Bool { manager != nil }

    private init() {}

    /// Lädt die Modelle einmalig und hält sie danach im Speicher.
    func ensureLoaded() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(progressHandler: { [weak self] progress in
                let text: String
                switch progress.phase {
                case .listing:
                    text = "Prüfe Parakeet-Modell …"
                case .downloading(let done, let total):
                    text = "Lade Parakeet-Modell … \(Int(progress.fractionCompleted * 100)) % (\(done)/\(total) Dateien)"
                case .compiling(let name):
                    text = "Kompiliere \(name) …"
                }
                DispatchQueue.main.async {
                    self?.loadProgress = progress.fractionCompleted
                    self?.onProgress?(progress.fractionCompleted, text)
                }
            })
            return AsrManager(config: .default, models: models)
        }
        loadTask = task
        do {
            let manager = try await task.value
            self.manager = manager
            return manager
        } catch {
            loadTask = nil
            throw error
        }
    }

    func makeSession(context: DictationContext) -> TranscriptionSession {
        LocalSession(engine: self)
    }

    private final class LocalSession: TranscriptionSession {
        private let engine: LocalParakeetEngine
        private var samples: [Int16] = []
        private let lock = NSLock()

        init(engine: LocalParakeetEngine) {
            self.engine = engine
            // Modelle schon während der Aufnahme laden — spart Latenz beim ersten Diktat.
            Task { _ = try? await engine.ensureLoaded() }
        }

        func append(packet: [Int16], volume: Float) {
            lock.lock()
            samples.append(contentsOf: packet)
            lock.unlock()
        }

        private func snapshotSamples() -> [Int16] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }

        func finish() async throws -> String {
            let collected = snapshotSamples()
            let engine = self.engine

            do {
                // 30 s decken Laden von Platte + Transkription locker ab; nur der
                // Erst-Download dauert länger — dann lieber schnell und mit
                // Fortschritt scheitern statt minutenlang stumm zu hängen.
                return try await withTimeout(seconds: 30) {
                    let manager = try await engine.ensureLoaded()
                    let floats = collected.map { Float($0) / 32768.0 }
                    var decoderState = TdtDecoderState.make()
                    let result = try await manager.transcribe(floats, decoderState: &decoderState)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw TranscriptionError.emptyResult }
                    return text
                }
            } catch TranscriptionError.timeout where !engine.isLoaded {
                throw TranscriptionError.server(
                    "Modell lädt noch (\(Int(engine.loadProgress * 100)) %) — gleich nochmal versuchen.")
            }
        }

        func cancel() {}
    }
}
