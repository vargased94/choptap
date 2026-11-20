import AVFoundation
import os

enum AudioTools {
    /// Calcula picos (máximo absoluto por bloque de `framesPerPeak` frames) leyendo el archivo por partes.
    static func peaks(of url: URL, framesPerPeak: Int = SystemAudioRecorder.framesPerPeak) throws -> (peaks: [Float], frames: AVAudioFramePosition, sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = AVAudioFrameCount(framesPerPeak * 512)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return ([], 0, format.sampleRate) }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(file.length) / framesPerPeak + 1)
        var acc: Float = 0
        var count = 0
        let channels = Int(format.channelCount)

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<Int(buffer.frameLength) {
                var v: Float = 0
                for c in 0..<channels { v = max(v, abs(data[c][i])) }
                acc = max(acc, v)
                count += 1
                if count == framesPerPeak {
                    peaks.append(acc); acc = 0; count = 0
                }
            }
        }
        if count > 0 { peaks.append(acc) }
        return (peaks, file.length, format.sampleRate)
    }

    static func read(_ url: URL, from start: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let start = max(0, min(start, file.length))
        let count = min(count, AVAudioFrameCount(file.length - start))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(count, 1)) else {
            throw RecorderError.noAudio
        }
        file.framePosition = start
        if count > 0 { try file.read(into: buffer, frameCount: count) }
        return buffer
    }

    struct ExportOptions: Hashable {
        var fadeMs: Double = 2
        var normalize = false
        var bitDepth = 24
    }

    /// Exporta un rango a WAV PCM (24 bits por defecto), con fades cortos para evitar clics.
    static func exportWAV(from url: URL, start: AVAudioFramePosition, count: AVAudioFrameCount,
                          to dest: URL, options: ExportOptions,
                          transform: ((AVAudioPCMBuffer) -> AVAudioPCMBuffer)? = nil) throws {
        let raw = try read(url, from: start, count: count)
        let buffer = transform?(raw) ?? raw
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, let data = buffer.floatChannelData else { throw RecorderError.noAudio }

        if options.normalize {
            var peak: Float = 0
            for c in 0..<channels { for i in 0..<frames { peak = max(peak, abs(data[c][i])) } }
            if peak > 0.0001 {
                let gain = Float(pow(10.0, -0.3 / 20.0)) / peak // -0.3 dBFS
                for c in 0..<channels { for i in 0..<frames { data[c][i] *= gain } }
            }
        }

        let fadeFrames = min(frames / 2, Int(options.fadeMs / 1000 * buffer.format.sampleRate))
        if fadeFrames > 1 {
            for i in 0..<fadeFrames {
                let g = Float(i) / Float(fadeFrames)
                for c in 0..<channels {
                    data[c][i] *= g
                    data[c][frames - 1 - i] *= g
                }
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: options.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: dest)
        let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buffer)
    }
}

/// Reproductor sencillo para escuchar la selección (con bucle opcional).
final class ClipPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var nodeFormat: AVAudioFormat?

    // Estado compartido con el hilo de audio (protegido por `lock`)
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var buffer: AVAudioPCMBuffer?
    private var position = 0
    private var rendered = 0
    private var loopFlag = false
    private var active = false
    private var processor: LoFiProcessor?

    private(set) var startSeconds: Double = 0
    private(set) var lengthSeconds: Double = 0
    private var sampleRate: Double = 48_000

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    var looping: Bool { withLock { loopFlag } }
    var isPlaying: Bool { withLock { active } }

    /// Tiempo transcurrido desde que empezó a sonar el buffer.
    var elapsed: Double? {
        withLock { active ? Double(rendered) / sampleRate : nil }
    }

    /// Reproduce `buffer` aplicando el lo-fi en tiempo real (se puede cambiar mientras suena).
    func play(_ buffer: AVAudioPCMBuffer, startSeconds: Double, loop: Bool,
              lofi: LoFiSettings = LoFiSettings(), seed: UInt64 = 1) throws {
        prepareNode(for: buffer.format)
        let processor = LoFiProcessor(settings: lofi, channels: Int(buffer.format.channelCount),
                                      sampleRate: buffer.format.sampleRate, seed: seed)
        withLock {
            self.buffer = buffer
            self.position = 0
            self.rendered = 0
            self.loopFlag = loop
            self.processor = processor
            self.active = buffer.frameLength > 0
        }
        self.startSeconds = startSeconds
        self.lengthSeconds = Double(buffer.frameLength) / buffer.format.sampleRate
        self.sampleRate = buffer.format.sampleRate
        if !engine.isRunning { try engine.start() }
    }

    /// Cambia el lo-fi al instante, sin reiniciar la reproducción.
    func updateLoFi(_ settings: LoFiSettings) {
        withLock { processor?.update(settings) }
    }

    func stop() {
        withLock {
            active = false
            buffer = nil
        }
    }

    private func prepareNode(for format: AVAudioFormat) {
        if sourceNode != nil, nodeFormat == format { return }
        if let old = sourceNode {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            self.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        nodeFormat = format
    }

    /// Hilo de audio: lee del buffer, aplica el lo-fi y escribe en la salida.
    private func render(frameCount: Int, into abl: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard active, let buffer, let src = buffer.floatChannelData, let processor else {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let length = Int(buffer.frameLength)
        let channels = min(out.count, Int(buffer.format.channelCount))
        for f in 0..<frameCount {
            if position >= length {
                if loopFlag {
                    position = 0
                } else {
                    for c in 0..<out.count {
                        out[c].mData?.assumingMemoryBound(to: Float.self)[f] = 0
                    }
                    active = false
                    continue
                }
            }
            processor.process(src: UnsafePointer(src), length: length, index: position, loop: loopFlag)
            for c in 0..<channels {
                out[c].mData?.assumingMemoryBound(to: Float.self)[f] = processor.output[c]
            }
            position += 1
            rendered += 1
        }
    }
}
