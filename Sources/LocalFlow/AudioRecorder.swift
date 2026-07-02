import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Nimmt über AVCaptureSession auf (der dokumentierte Weg, ein bestimmtes
/// Mikrofon zu wählen) und liefert 50-ms-Pakete — 800 Samples, 16 kHz mono
/// Int16, das Format, das alle Engines direkt verarbeiten können.
/// Die Format-Konvertierung übernimmt CoreMedia über `audioSettings`.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 16_000.0
    static let packetSamples = 800 // 50 ms

    var onPacket: (([Int16], Float) -> Void)?
    private(set) var isRunning = false

    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "ai.evalent.localflow.capture")
    private var pending: [Int16] = []
    private var startedAt: Date?
    private var loggedFirstPacket = false
    private var peakLevel: Float = 0

    func start() throws {
        guard !isRunning else { return }
        pending.removeAll()
        startedAt = Date()
        loggedFirstPacket = false
        peakLevel = 0

        guard let device = Self.captureDevice() else {
            throw TranscriptionError.server("Kein Mikrofon gefunden.")
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw TranscriptionError.server("Mikrofon \(device.localizedName) nicht nutzbar.")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw TranscriptionError.server("Audio-Ausgabe nicht konfigurierbar.")
        }
        session.addOutput(output)

        self.session = session
        isRunning = true
        FlowLog.log("Aufnahme über: \(device.localizedName)")
        // startRunning blockiert kurz — nicht auf dem Main-Thread ausführen.
        captureQueue.async { session.startRunning() }
    }

    func stop() {
        guard isRunning, let session else { return }
        isRunning = false
        // Synchron auf der Capture-Queue: erst stoppen, dann letzte Puffer
        // verarbeiten und das Teilpaket auffüllen (Wispr verlangt konstante
        // Paketlängen) — danach ist garantiert alles emittiert.
        captureQueue.sync {
            session.stopRunning()
            if !self.pending.isEmpty {
                var last = self.pending
                last.append(contentsOf: [Int16](repeating: 0, count: Self.packetSamples - last.count))
                self.pending.removeAll()
                self.emit(packet: last)
            }
        }
        self.session = nil
        FlowLog.log("Aufnahme beendet, Spitzenpegel \(String(format: "%.2f", peakLevel)).")
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate (läuft auf captureQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length >= 2 else { return }

        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else {
            return
        }
        bytes.withUnsafeBytes { raw in
            pending.append(contentsOf: raw.bindMemory(to: Int16.self))
        }

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
        if !loggedFirstPacket, let startedAt {
            loggedFirstPacket = true
            FlowLog.log("Erstes Audio-Paket nach \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms.")
        }
        peakLevel = max(peakLevel, rms)
        onPacket?(packet, min(1.0, rms * 4)) // grob auf 0…1 skaliert
    }

    // MARK: Gerätewahl

    /// Explizit gewähltes Gerät, sonst integriertes Mikrofon (sofort bereit),
    /// zuletzt der Systemstandard. Jede Stufe wird geloggt.
    private static func captureDevice() -> AVCaptureDevice? {
        let chosenUID = AppSettings.micDeviceUID
        if !chosenUID.isEmpty {
            if let device = AVCaptureDevice(uniqueID: chosenUID) {
                return device
            }
            FlowLog.log("Gewähltes Mikrofon (\(chosenUID)) nicht gefunden — nutze Automatik.")
        }
        if let builtInUID = builtInInputDeviceUID() {
            if let device = AVCaptureDevice(uniqueID: builtInUID) {
                return device
            }
            FlowLog.log("Integriertes Mikrofon (\(builtInUID)) nicht via AVCapture erreichbar.")
        } else {
            FlowLog.log("Kein integriertes Mikrofon gefunden (CoreAudio).")
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// CoreAudio-UID des integrierten Mikrofons (Transport "Built-in" mit
    /// Eingabekanälen) — dient als uniqueID für AVCaptureDevice.
    private static func builtInInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        for device in devices {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &configAddress, 0, nil, &configSize) == noErr,
                  configSize > 0 else { continue }
            let rawList = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawList.deallocate() }
            guard AudioObjectGetPropertyData(device, &configAddress, 0, nil, &configSize, rawList) == noErr else { continue }
            let bufferList = UnsafeMutableAudioBufferListPointer(rawList.assumingMemoryBound(to: AudioBufferList.self))
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let uid else { continue }
            return uid.takeRetainedValue() as String
        }
        return nil
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
