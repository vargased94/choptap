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

/// Procesado offline (exportar): usa el mismo procesador que la reproducción en tiempo real,
/// así lo que oyes es exactamente lo que exportas. Determinista para una misma semilla.
enum LoFi {
    static func process(_ input: AVAudioPCMBuffer, settings s: LoFiSettings, seed: UInt64 = 1) -> AVAudioPCMBuffer {
        guard s.enabled, let src = input.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let dst = out.floatChannelData else { return input }
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        out.frameLength = input.frameLength
        let processor = LoFiProcessor(settings: s, channels: channels, sampleRate: input.format.sampleRate, seed: seed)
        for i in 0..<frames {
            processor.process(src: UnsafePointer(src), length: frames, index: i, loop: false)
            for c in 0..<channels { dst[c][i] = processor.output[c] }
        }
        return out
    }
}

/// Cadena lo-fi con estado, muestra a muestra. Se puede cambiar de ajustes en cualquier momento
/// (`update`) sin reiniciar: los filtros conservan su estado y el cambio es instantáneo y sin cortes.
/// Etapas: wow/flutter → antialias opcional → sample & hold → bits → ruido → compresión → saturación → filtro de salida.
final class LoFiProcessor {
    private(set) var settings: LoFiSettings
    let channels: Int
    let sampleRate: Double
    /// Muestra resultante de cada canal tras `process`.
    private(set) var output: [Float]

    // Parámetros derivados
    private var wowDepth = 0.0, flutterDepth = 0.0, baseDelay = 2.0
    private let wowRate = 0.55, flutterRate = 6.3
    private var reduceRate = false, holdStep = 1.0
    private var quantize = false, levels = 32768.0
    private var threshold = 1.0, ratio = 1.0, attack = 0.0, release = 0.0, makeup = 1.0
    private var driveGain = 1.0, driveNorm = 1.0
    private var useOutputFilter = false
    private var crackleRate = 0.0, hissLevel = 0.0, crackleLevel = 0.0

    // Estado
    private var rng: SplitMix64
    private let wowPhase0: Double
    private var wowRandom = 0.0
    private var counter = 0.0
    private var pre1: [Biquad], pre2: [Biquad], postA: [Biquad], postB: [Biquad]
    private var hissLP: Biquad, hissHP: Biquad
    private var crackle = 0.0
    private var held: [Double]
    private var holdPhase = 1.0
    private var envelope = 0.0
    private var tmp: [Double]

    init(settings: LoFiSettings, channels: Int, sampleRate: Double, seed: UInt64) {
        self.settings = settings
        self.channels = channels
        self.sampleRate = sampleRate
        var r = SplitMix64(seed: seed)
        wowPhase0 = Double(r.next() % 1000) / 1000 * 2 * .pi
        rng = r
        let identity = Biquad()
        pre1 = Array(repeating: identity, count: channels)
        pre2 = pre1; postA = pre1; postB = pre1
        hissLP = Biquad.lowpass(freq: 5_000, q: 0.7, sr: sampleRate)
        hissHP = Biquad.highpass(freq: 400, q: 0.7, sr: sampleRate)
        held = Array(repeating: 0, count: channels)
        tmp = Array(repeating: 0, count: channels)
        output = Array(repeating: 0, count: channels)
        configure()
    }

    /// Cambia los ajustes al vuelo conservando el estado interno.
    func update(_ s: LoFiSettings) {
        guard s != settings else { return }
        settings = s
        configure()
    }

    private func configure() {
        let s = settings, sr = sampleRate
        wowDepth = s.wow * 0.0022 * sr
        flutterDepth = s.wow * 0.00025 * sr
        baseDelay = 0.0024 * sr + 0.00025 * sr + 2   // retardo fijo: el máximo posible, para que mover el wow no salte

        reduceRate = s.sampleRate < sr - 1
        holdStep = reduceRate ? s.sampleRate / sr : 1
        let pre = Biquad.lowpass(freq: min(s.sampleRate * 0.45, sr * 0.45), q: 0.707, sr: sr)
        for c in 0..<channels { pre1[c].setCoefficients(from: pre); pre2[c].setCoefficients(from: pre) }

        quantize = s.bits < 15.9
        levels = pow(2.0, s.bits - 1)

        threshold = pow(10, (-6 - 24 * s.compression) / 20)
        ratio = 1 + 9 * s.compression
        attack = exp(-1 / (0.0008 * sr))
        release = exp(-1 / ((0.06 + 0.12 * (1 - s.compression)) * sr))
        makeup = s.compression > 0 ? pow(1 / threshold, 1 - 1 / ratio) * 0.55 : 1

        driveGain = 1 + s.drive * 5
        driveNorm = 1 / tanh(driveGain)

        let cutoff = min(s.filterHz, sr * 0.45)
        let a = Biquad.lowpass(freq: cutoff, q: 0.54, sr: sr), b = Biquad.lowpass(freq: cutoff, q: 1.31, sr: sr)
        for c in 0..<channels { postA[c].setCoefficients(from: a); postB[c].setCoefficients(from: b) }
        useOutputFilter = s.filterHz < 19_500

        crackleRate = s.noise * 9 / sr
        hissLevel = s.noise * 0.012
        crackleLevel = s.noise * 0.25
    }

    @inline(__always)
    private func read(_ src: UnsafePointer<UnsafeMutablePointer<Float>>, _ c: Int, _ idx: Int, _ length: Int, _ loop: Bool) -> Double {
        if idx >= 0 && idx < length { return Double(src[c][idx]) }
        guard loop, length > 0 else { return 0 }
        let wrapped = ((idx % length) + length) % length
        return Double(src[c][wrapped])
    }

    /// Procesa el frame `index` de `src` y deja el resultado en `output`.
    func process(src: UnsafePointer<UnsafeMutablePointer<Float>>, length: Int, index i: Int, loop: Bool) {
        let s = settings
        guard s.enabled else {
            for c in 0..<channels { output[c] = src[c][i] }
            counter += 1
            return
        }

        // Wow/flutter
        if s.wow > 0 {
            let t = counter / sampleRate
            wowRandom += (Double(rng.nextUnit()) - 0.5) * 0.002
            wowRandom *= 0.9995
            let mod = sin(2 * .pi * wowRate * t + wowPhase0) * wowDepth
                + sin(2 * .pi * flutterRate * t) * flutterDepth
                + wowRandom * wowDepth
            let pos = Double(i) - baseDelay - mod
            let p0 = Int(pos.rounded(.down)), frac = pos - pos.rounded(.down)
            for c in 0..<channels {
                let a = read(src, c, p0, length, loop), b = read(src, c, p0 + 1, length, loop)
                tmp[c] = a + (b - a) * frac
            }
        } else {
            for c in 0..<channels { tmp[c] = Double(src[c][i]) }
        }
        counter += 1

        // Reducción de muestreo (sample & hold), con antialias opcional
        if reduceRate {
            if !s.aliasing {
                for c in 0..<channels { tmp[c] = pre2[c].process(pre1[c].process(tmp[c])) }
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
            let hiss = hissHP.process(hissLP.process(Double(rng.nextUnit()) * 2 - 1)) * hissLevel
            if Double(rng.nextUnit()) < crackleRate {
                crackle = (Double(rng.nextUnit()) * 2 - 1) * crackleLevel
            }
            let click = crackle
            crackle *= 0.62
            for c in 0..<channels { tmp[c] += hiss + click * (c == 0 ? 1 : 0.85) }
        }

        // Compresión estilo Vinyl Sim: rápida y enlazada en estéreo
        if s.compression > 0 {
            var peak = 0.0
            for c in 0..<channels { peak = max(peak, abs(tmp[c])) }
            let coeff = peak > envelope ? attack : release
            envelope = coeff * envelope + (1 - coeff) * peak
            var gain = 1.0
            if envelope > threshold { gain = pow(threshold / envelope, 1 - 1 / ratio) }
            for c in 0..<channels { tmp[c] *= gain * makeup }
        }

        // Saturación
        for c in 0..<channels {
            tmp[c] = s.drive > 0 ? tanh(tmp[c] * driveGain) * driveNorm : Self.softClip(tmp[c])
        }

        // Filtro de salida (reconstrucción) de 4 polos
        if useOutputFilter {
            for c in 0..<channels { tmp[c] = postB[c].process(postA[c].process(tmp[c])) }
        }

        // Limitador suave final: nunca pasa de 0 dBFS
        for c in 0..<channels { output[c] = Float(Self.softClip(tmp[c] * 0.98)) }
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

    /// Cambia los coeficientes conservando el estado (sin clics al mover un control).
    mutating func setCoefficients(from other: Biquad) {
        b0 = other.b0; b1 = other.b1; b2 = other.b2; a1 = other.a1; a2 = other.a2
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
