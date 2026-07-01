import AVFoundation
import Foundation

/// Nimmt vom Standard-Mikrofon auf und liefert 50-ms-Pakete
/// (800 Samples, 16 kHz mono Int16) — das Format, das alle drei
/// Engines (Parakeet, Wispr, ElevenLabs) direkt verarbeiten können.
final class AudioRecorder {
    static let sampleRate = 16_000.0
    static let packetSamples = 800 // 50 ms

    var onPacket: (([Int16], Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pending: [Int16] = []
    private(set) var isRunning = false

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!

    func start() throws {
        guard !isRunning else { return }
        pending.removeAll()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriptionError.server("Audio-Konvertierung (\(Int(inFormat.sampleRate)) Hz → 16 kHz) nicht möglich.")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        // Letztes Teilpaket mit Stille auffüllen — die Wispr-API verlangt
        // Pakete konstanter Länge.
        if !pending.isEmpty {
            var last = pending
            last.append(contentsOf: [Int16](repeating: 0, count: Self.packetSamples - last.count))
            emit(packet: last)
            pending.removeAll()
        }
        converter = nil
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = outBuffer.int16ChannelData else { return }

        let frames = Int(outBuffer.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))

        while pending.count >= Self.packetSamples {
            let packet = Array(pending.prefix(Self.packetSamples))
            pending.removeFirst(Self.packetSamples)
            emit(packet: packet)
        }
    }

    private func emit(packet: [Int16]) {
        var sum = 0.0
        for sample in packet {
            let normalized = Double(sample) / 32768.0
            sum += normalized * normalized
        }
        let rms = Float((sum / Double(packet.count)).squareRoot())
        onPacket?(packet, min(1.0, rms * 4)) // grob auf 0…1 skaliert
    }
}

/// Baut aus 16-kHz-mono-Int16-Samples eine komplette WAV-Datei (RIFF-Header).
enum WavEncoder {
    static func encode(samples: [Int16], sampleRate: Int = 16_000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // fmt-Chunk-Größe
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))           // Byte-Rate
        append(UInt16(2))                        // Block-Align
        append(UInt16(16))                       // Bits pro Sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Rohe PCM-Bytes (little-endian) ohne Header — Format der Wispr-Pakete.
    static func rawBytes(samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
