import AVFoundation

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
    private let node = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?

    private(set) var startSeconds: Double = 0
    private(set) var lengthSeconds: Double = 0
    private(set) var looping = false
    var isPlaying: Bool { node.isPlaying }

    init() { engine.attach(node) }

    func play(_ buffer: AVAudioPCMBuffer, startSeconds: Double, loop: Bool) throws {
        stop()
        if connectedFormat != buffer.format {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engine.isRunning { try engine.start() }
        self.startSeconds = startSeconds
        self.lengthSeconds = Double(buffer.frameLength) / buffer.format.sampleRate
        self.looping = loop
        node.scheduleBuffer(buffer, at: nil, options: loop ? [.loops] : [], completionHandler: nil)
        node.play()
    }

    /// Tiempo transcurrido desde que empezó a sonar el buffer.
    var elapsed: Double? {
        guard node.isPlaying, let nodeTime = node.lastRenderTime,
              let t = node.playerTime(forNodeTime: nodeTime) else { return nil }
        return max(0, Double(t.sampleTime) / t.sampleRate)
    }

    func stop() {
        node.stop()
    }
}
