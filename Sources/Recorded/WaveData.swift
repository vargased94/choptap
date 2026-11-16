import AVFoundation
import SwiftUI

/// Datos de forma de onda en varias resoluciones (como hacen Slicex, Audacity, etc.):
/// - `samples`: muestras reales (mezcla mono) para el zoom extremo.
/// - Nivel 1: mínimo/máximo cada 64 muestras.
/// - Nivel 2: mínimo/máximo cada 1024 muestras.
/// Al dibujar se elige el nivel adecuado para cada columna de píxeles.
final class WaveData {
    static let level1Size = 64
    static let level2Size = 1024

    let sampleRate: Double
    let samples: [Float]
    private let min1: [Float], max1: [Float]
    private let min2: [Float], max2: [Float]

    /// Ganancia solo visual para que la onda ocupe la altura (como Slicex). No afecta al audio.
    let displayGain: Float

    var frameCount: Int { samples.count }
    var duration: Double { Double(samples.count) / sampleRate }

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        sampleRate = format.sampleRate
        let total = Int(file.length)
        let channels = Int(format.channelCount)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw RecorderError.noAudio }

        var mono = [Float](repeating: 0, count: total)
        let bins1 = (total + Self.level1Size - 1) / Self.level1Size
        var lo1 = [Float](repeating: .greatestFiniteMagnitude, count: max(bins1, 1))
        var hi1 = [Float](repeating: -.greatestFiniteMagnitude, count: max(bins1, 1))

        var pos = 0
        while pos < total {
            try file.read(into: buffer, frameCount: chunk)
            let n = min(Int(buffer.frameLength), total - pos)
            guard n > 0, let data = buffer.floatChannelData else { break }
            mono.withUnsafeMutableBufferPointer { m in
                lo1.withUnsafeMutableBufferPointer { lo in
                    hi1.withUnsafeMutableBufferPointer { hi in
                        for i in 0..<n {
                            var sum: Float = 0, fmin: Float = .greatestFiniteMagnitude, fmax: Float = -.greatestFiniteMagnitude
                            for c in 0..<channels {
                                let v = data[c][i]
                                sum += v
                                fmin = Swift.min(fmin, v)
                                fmax = Swift.max(fmax, v)
                            }
                            let f = pos + i
                            m[f] = sum / Float(channels)
                            let b = f / Self.level1Size
                            lo[b] = Swift.min(lo[b], fmin)
                            hi[b] = Swift.max(hi[b], fmax)
                        }
                    }
                }
            }
            pos += n
        }
        if pos < total { mono.removeLast(total - pos) }
        for b in 0..<lo1.count where lo1[b] > hi1[b] { lo1[b] = 0; hi1[b] = 0 }

        let factor = Self.level2Size / Self.level1Size
        let bins2 = (lo1.count + factor - 1) / factor
        var lo2 = [Float](repeating: 0, count: max(bins2, 1))
        var hi2 = [Float](repeating: 0, count: max(bins2, 1))
        for b in 0..<bins2 {
            let a = b * factor, e = Swift.min(a + factor, lo1.count)
            var l: Float = .greatestFiniteMagnitude, h: Float = -.greatestFiniteMagnitude
            for k in a..<e { l = Swift.min(l, lo1[k]); h = Swift.max(h, hi1[k]) }
            lo2[b] = l; hi2[b] = h
        }

        // Percentil 99 de los picos: un golpe aislado no aplasta el resto de la onda.
        let levels = (0..<lo2.count).map { Swift.max(abs(lo2[$0]), abs(hi2[$0])) }.sorted()
        let peak = levels.isEmpty ? 0 : levels[Swift.min(levels.count - 1, Int(Double(levels.count) * 0.99))]
        displayGain = peak > 0.0001 ? Swift.min(10, 0.9 / peak) : 1

        samples = mono
        min1 = lo1; max1 = hi1
        min2 = lo2; max2 = hi2
    }

    /// Mínimo y máximo en el rango de frames [a, b).
    func minMax(_ a: Int, _ b: Int) -> (Float, Float) {
        let a = Swift.max(0, a), b = Swift.min(frameCount, b)
        guard b > a else { return (0, 0) }
        let count = b - a
        var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
        if count >= Self.level2Size * 2 {
            for k in (a / Self.level2Size)...((b - 1) / Self.level2Size) { lo = Swift.min(lo, min2[k]); hi = Swift.max(hi, max2[k]) }
        } else if count >= Self.level1Size * 2 {
            for k in (a / Self.level1Size)...((b - 1) / Self.level1Size) { lo = Swift.min(lo, min1[k]); hi = Swift.max(hi, max1[k]) }
        } else {
            for k in a..<b { lo = Swift.min(lo, samples[k]); hi = Swift.max(hi, samples[k]) }
        }
        return (lo, hi)
    }

    /// Construye el contorno relleno (máximos arriba, mínimos abajo) para el rango de tiempo dado.
    /// `columns` es la cantidad de columnas (normalmente píxeles) a usar.
    func envelopePath(from t0: Double, to t1: Double, width: CGFloat, columns: Int,
                      midY: CGFloat, halfHeight: CGFloat) -> Path {
        var path = Path()
        guard columns > 0, t1 > t0 else { return path }
        var tops: [CGPoint] = [], bottoms: [CGPoint] = []
        tops.reserveCapacity(columns + 1); bottoms.reserveCapacity(columns + 1)
        let span = t1 - t0
        for c in 0...columns {
            let ta = t0 + span * Double(c) / Double(columns)
            let tb = t0 + span * Double(c + 1) / Double(columns)
            let fa = Int(ta * sampleRate), fb = Swift.max(fa + 1, Int(tb * sampleRate))
            if fa >= frameCount { break }
            var (lo, hi) = minMax(fa, fb)
            lo *= displayGain; hi *= displayGain
            let x = width * CGFloat(c) / CGFloat(columns)
            // Siempre al menos ~0.5 pt de grosor para que el silencio se vea como una línea.
            tops.append(CGPoint(x: x, y: midY - Swift.max(CGFloat(Swift.min(hi, 1)) * halfHeight, 0.5)))
            bottoms.append(CGPoint(x: x, y: midY - Swift.min(CGFloat(Swift.max(lo, -1)) * halfHeight, -0.5)))
        }
        guard let first = tops.first else { return path }
        path.move(to: first)
        for p in tops.dropFirst() { path.addLine(to: p) }
        for p in bottoms.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}
