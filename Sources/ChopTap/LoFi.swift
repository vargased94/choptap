import AVFoundation

/// Ajustes del efecto lo-fi inspirado en samplers clásicos (Vinyl Sim de los SP, samplers de 12 bits).
struct LoFiSettings: Codable, Hashable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case vinyl303, vinyl404, bit12, sampler90s, cassette, crushed, custom
        var id: String { rawValue }

        var name: String {
            switch self {
            case .vinyl303: return "Vinilo 303"
            case .vinyl404: return "Vinilo 404"
            case .bit12: return "12-bit 26k"
            case .sampler90s: return "Sampler 90s"
            case .cassette: return "Cassette"
            case .crushed: return "Destrozado"
            case .custom: return "Personalizado"
            }
        }

        var detail: String {
            switch self {
            case .vinyl303: return "Compresión sucia, crujido y wow (estilo Vinyl Sim del SP-303)"
            case .vinyl404: return "Vinilo más suave y oscuro (estilo Vinyl Sim del SP-404)"
            case .bit12: return "12 bits a 26,04 kHz con aliasing (sampler clásico de los 80)"
            case .sampler90s: return "12 bits filtrado y cálido (samplers de los 90)"
            case .cassette: return "Cinta: saturación, siseo y wow"
            case .crushed: return "8 bits a 11 kHz, sucio a propósito"
            case .custom: return "Tus ajustes"
            }
        }
    }

    var enabled = false
    var preset: Preset = .vinyl303
    /// Profundidad en bits (4…16).
    var bits: Double = 16
    /// Frecuencia de muestreo objetivo en Hz (≥ la del audio = sin reducción).
    var sampleRate: Double = 48_000
    /// Sin filtro antialias: deja el aliasing metálico típico de los samplers de 12 bits.
    var aliasing = true
    /// Filtro de salida (paso bajo) en Hz.
    var filterHz: Double = 20_000
    /// Compresión estilo Vinyl Sim (0…1).
    var compression: Double = 0
    /// Saturación (0…1).
    var drive: Double = 0
    /// Ruido de vinilo / cinta (0…1).
    var noise: Double = 0
    /// Wow y flutter (0…1).
    var wow: Double = 0

    static func preset(_ p: Preset) -> LoFiSettings {
        var s = LoFiSettings()
        s.preset = p
        switch p {
        case .vinyl303:
            s.compression = 0.75; s.noise = 0.35; s.wow = 0.3; s.filterHz = 9_000; s.drive = 0.2
        case .vinyl404:
            s.compression = 0.4; s.noise = 0.25; s.wow = 0.15; s.filterHz = 6_300; s.drive = 0.1
        case .bit12:
            s.bits = 12; s.sampleRate = 26_040; s.aliasing = true; s.filterHz = 12_000; s.compression = 0.2; s.drive = 0.15
        case .sampler90s:
            s.bits = 12; s.sampleRate = 32_000; s.aliasing = false; s.filterHz = 8_000; s.compression = 0.25; s.drive = 0.1
        case .cassette:
            s.wow = 0.45; s.noise = 0.3; s.filterHz = 7_500; s.drive = 0.35; s.compression = 0.3
        case .crushed:
            s.bits = 8; s.sampleRate = 11_025; s.aliasing = true; s.filterHz = 4_500; s.drive = 0.5; s.compression = 0.35; s.noise = 0.15
        case .custom:
            break
        }
        return s
    }

    /// Clave de caché para exportar (solo cuenta si está activo).
    var cacheKey: String { enabled ? "\(hashValue)" : "off" }
}

/// Procesador offline: devuelve un buffer nuevo con el efecto aplicado.
/// Es determinista (misma entrada y semilla → mismo resultado) para que lo que oyes sea lo que exportas.
enum LoFi {
    static func process(_ input: AVAudioPCMBuffer, settings s: LoFiSettings, seed: UInt64 = 1) -> AVAudioPCMBuffer {
        guard s.enabled, let src = input.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let dst = out.floatChannelData else { return input }
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        let sr = input.format.sampleRate
        out.frameLength = input.frameLength
        guard frames > 0 else { return out }

        var rng = SplitMix64(seed: seed)

        // 1. Wow & flutter: línea de retardo modulada (vinilo/cinta girando irregular)
        let wowDepth = s.wow * 0.0022 * sr           // hasta ~2,2 ms de variación
        let flutterDepth = s.wow * 0.00025 * sr
        let baseDelay = wowDepth + flutterDepth + 2
        let wowRate = 0.55, flutterRate = 6.3
        let wowPhase0 = Double(rng.next() % 1000) / 1000 * 2 * .pi
        var wowRandom = 0.0

        // 2. Antialias (si no queremos aliasing) y reducción de muestreo (sample & hold)
        let reduceRate = s.sampleRate < sr - 1
        let holdStep = reduceRate ? s.sampleRate / sr : 1
        var preFilters = (0..<channels).map { _ in Biquad.lowpass(freq: min(s.sampleRate * 0.45, sr * 0.45), q: 0.707, sr: sr) }
        var preFilters2 = preFilters

        // 3. Bits
        let quantize = s.bits < 15.9
        let levels = pow(2.0, s.bits - 1)

        // 5. Compresión estilo Vinyl Sim: rápida, enlazada en estéreo, con ganancia de compensación
        let threshold = pow(10, (-6 - 24 * s.compression) / 20)
        let ratio = 1 + 9 * s.compression
        let attack = exp(-1 / (0.0008 * sr))
        let release = exp(-1 / ((0.06 + 0.12 * (1 - s.compression)) * sr))
        let makeup = s.compression > 0 ? pow(1 / threshold, 1 - 1 / ratio) * 0.55 : 1
        var envelope = 0.0

        // 6. Saturación
        let driveGain = 1 + s.drive * 5
        let driveNorm = 1 / tanh(driveGain)

        // 7. Filtro de salida (reconstrucción) de 4 polos
        let cutoff = min(s.filterHz, sr * 0.45)
        var postA = (0..<channels).map { _ in Biquad.lowpass(freq: cutoff, q: 0.54, sr: sr) }
        var postB = (0..<channels).map { _ in Biquad.lowpass(freq: cutoff, q: 1.31, sr: sr) }
        let useOutputFilter = s.filterHz < 19_500

        // Ruido: siseo filtrado + crujidos esporádicos
        var hissFilter = Biquad.lowpass(freq: 5_000, q: 0.7, sr: sr)
        var hissHP = Biquad.highpass(freq: 400, q: 0.7, sr: sr)
        var crackle = 0.0
        let crackleRate = s.noise * 9 / sr            // crujidos por muestra
        let hissLevel = s.noise * 0.012
        let crackleLevel = s.noise * 0.25

        var held = [Double](repeating: 0, count: channels)
        var holdPhase = 1.0
        var tmp = [Double](repeating: 0, count: channels)

        for i in 0..<frames {
            // Wow/flutter
            if s.wow > 0 {
                let t = Double(i) / sr
                wowRandom += (Double(rng.nextUnit()) - 0.5) * 0.002
                wowRandom *= 0.9995
                let mod = sin(2 * .pi * wowRate * t + wowPhase0) * wowDepth
                    + sin(2 * .pi * flutterRate * t) * flutterDepth
                    + wowRandom * wowDepth
                let pos = Double(i) - baseDelay - mod
                let p0 = Int(floor(pos)), frac = pos - floor(pos)
                for c in 0..<channels {
                    let a = (p0 >= 0 && p0 < frames) ? Double(src[c][p0]) : 0
                    let b = (p0 + 1 >= 0 && p0 + 1 < frames) ? Double(src[c][p0 + 1]) : 0
                    tmp[c] = a + (b - a) * frac
                }
            } else {
                for c in 0..<channels { tmp[c] = Double(src[c][i]) }
            }

            // Reducción de muestreo
            if reduceRate {
                if !s.aliasing {
                    for c in 0..<channels { tmp[c] = preFilters2[c].process(preFilters[c].process(tmp[c])) }
                }
                holdPhase += holdStep
                if holdPhase >= 1 {
                    holdPhase -= 1
                    for c in 0..<channels { held[c] = tmp[c] }
                }
                for c in 0..<channels { tmp[c] = held[c] }
            }

            // Bits (truncado sin dither, como los convertidores antiguos)
            if quantize {
                for c in 0..<channels { tmp[c] = (tmp[c] * levels).rounded(.towardZero) / levels }
            }

            // Ruido de vinilo (antes de la compresión: el compresor también lo "bombea")
            if s.noise > 0 {
                let hiss = hissHP.process(hissFilter.process(Double(rng.nextUnit()) * 2 - 1)) * hissLevel
                if Double(rng.nextUnit()) < crackleRate {
                    crackle = (Double(rng.nextUnit()) * 2 - 1) * crackleLevel
                }
                let click = crackle
                crackle *= 0.62
                for c in 0..<channels { tmp[c] += hiss + click * (c == 0 ? 1 : 0.85) }
            }

            // Compresión
            if s.compression > 0 {
                var peak = 0.0
                for c in 0..<channels { peak = max(peak, abs(tmp[c])) }
                let coeff = peak > envelope ? attack : release
                envelope = coeff * envelope + (1 - coeff) * peak
                var gain = 1.0
                if envelope > threshold { gain = pow(threshold / envelope, 1 - 1 / ratio) }
                for c in 0..<channels { tmp[c] *= gain * makeup }
            }

            // Saturación (siempre un poco de tanh para no pasar de 0 dBFS)
            for c in 0..<channels {
                tmp[c] = s.drive > 0 ? tanh(tmp[c] * driveGain) * driveNorm : softClip(tmp[c])
            }

            // Filtro de salida
            if useOutputFilter {
                for c in 0..<channels { tmp[c] = postB[c].process(postA[c].process(tmp[c])) }
            }

            // Limitador suave final: nunca pasa de 0 dBFS
            for c in 0..<channels { dst[c][i] = Float(softClip(tmp[c] * 0.98)) }
        }
        return out
    }

    private static func softClip(_ x: Double) -> Double {
        abs(x) < 0.9 ? x : (x > 0 ? 1 : -1) * (0.9 + 0.099 * tanh((abs(x) - 0.9) / 0.099))
    }
}

/// Filtro biquad (fórmulas RBJ).
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func lowpass(freq: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * max(10, min(freq, sr * 0.49)) / sr
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 - c) / 2 / a0; f.b1 = (1 - c) / a0; f.b2 = (1 - c) / 2 / a0
        f.a1 = -2 * c / a0; f.a2 = (1 - alpha) / a0
        return f
    }

    static func highpass(freq: Double, q: Double, sr: Double) -> Biquad {
        let w = 2 * .pi * max(10, min(freq, sr * 0.49)) / sr
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var f = Biquad()
        f.b0 = (1 + c) / 2 / a0; f.b1 = -(1 + c) / a0; f.b2 = (1 + c) / 2 / a0
        f.a1 = -2 * c / a0; f.a2 = (1 - alpha) / a0
        return f
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Generador pseudoaleatorio rápido y determinista.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
