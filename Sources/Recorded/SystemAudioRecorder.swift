import AVFoundation
import CoreMedia
import CoreAudio

enum RecorderError: LocalizedError {
    case noAudio
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No se recibió audio."
        case .coreAudio(let what, let status): return "\(what) (código \(status))."
        }
    }
}

struct RecordingOptions: Equatable {
    /// Espera a que suene algo por encima del umbral antes de empezar a grabar.
    var waitForAudio = true
    /// Umbral de detección en dBFS.
    var thresholdDB: Float = -50
    /// Detener sola tras este silencio (segundos). nil = no parar sola.
    var autoStopSeconds: Double? = nil
}

/// Captura todo el audio que se reproduce en el Mac (excepto el de esta app)
/// con un Core Audio Process Tap (macOS 14.2+) y lo escribe en un archivo CAF float32.
/// Usa el permiso "Solo grabación de audio del sistema", no el de grabación de pantalla.
final class SystemAudioRecorder: NSObject {
    static let framesPerPeak = 256
    private static let prerollSeconds = 0.15
    private static let silenceTailSeconds = 0.3

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "recorded.audio.capture", qos: .userInitiated)
    private var silenceTimer: DispatchSourceTimer?

    // Accedidos solo desde `queue`
    private var options = RecordingOptions()
    private var file: AVAudioFile?
    private var url: URL?
    private var firstPTS: CMTime?
    private var framesWritten: AVAudioFramePosition = 0
    private var peakAccumulator: Float = 0
    private var peakCount = 0
    private var triggered = false
    private var preroll: [(AVAudioPCMBuffer, CMTime)] = []
    private var pendingSilence: [(AVAudioPCMBuffer, CMTime)] = []
    private var lastLoudPTS: CMTime?
    private var autoStopFired = false

    /// Picos nuevos (máximo absoluto cada `framesPerPeak` frames). Se llama en main.
    var onPeaks: (([Float]) -> Void)?
    /// Nivel de entrada actual (también mientras espera audio). Se llama en main.
    var onLevel: ((Float) -> Void)?
    /// Empezó a grabar de verdad (se detectó audio). Se llama en main.
    var onTriggered: ((Double) -> Void)?
    /// Se cumplió el tiempo de silencio configurado. Se llama en main.
    var onAutoStop: (() -> Void)?
    var onStopWithError: ((Error) -> Void)?

    func start(writingTo url: URL, options: RecordingOptions) async throws {
        queue.sync {
            self.options = options
            self.url = url
            self.file = nil
            self.firstPTS = nil
            self.framesWritten = 0
            self.peakAccumulator = 0
            self.peakCount = 0
            self.triggered = false
            self.preroll = []
            self.pendingSilence = []
            self.lastLoudPTS = nil
            self.autoStopFired = false
        }
        do {
            try startTap()
        } catch {
            teardownTap()
            throw error
        }
        startSilenceTimer()
    }

    private func startTap() throws {
        // 1. Tap global estéreo de todos los procesos menos este.
        let exclude = Self.ownAudioProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "Recorded"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw RecorderError.coreAudio("No se pudo crear el tap de audio", status) }
        tapID = tap

        // 2. Formato del tap.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.coreAudio("No se pudo leer el formato del tap", status)
        }
        tapFormat = format

        // 3. Dispositivo agregado privado que contiene el tap.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            throw RecorderError.coreAudio("No se encontró la salida de audio", -1)
        }
        // Por defecto el dispositivo de captura contiene solo el tap y trabaja a su frecuencia nativa
        // (48 kHz): una conversión de frecuencia menos que incluyendo la salida (medido: más fiel).
        // Si no se puede crear, se usa el modo con la salida como reloj.
        let tapOnly = ProcessInfo.processInfo.environment["RECORDED_TAP_MODE"] != "output"
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recorded Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: !tapOnly,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if !tapOnly {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        if status != noErr, tapOnly {
            aggregate[kAudioAggregateDeviceUIDKey] = UUID().uuidString
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            aggregate[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        }
        guard status == noErr else { throw RecorderError.coreAudio("No se pudo crear el dispositivo de captura", status) }
        aggregateID = agg

        // El audio llega a la frecuencia del dispositivo agregado (la de la salida, p. ej. 44.1 kHz),
        // que puede no coincidir con la que anuncia el tap (p. ej. 48 kHz).
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, &rate) == noErr, rate > 0, rate != asbd.mSampleRate {
            asbd.mSampleRate = rate
            if let corrected = AVAudioFormat(streamDescription: &asbd) { tapFormat = corrected }
        }

        // 4. Callback de entrada (en nuestra cola serie).
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let format = self.tapFormat, let copy = Self.standardBuffer(from: inputData, tapFormat: format) else { return }
            let host = inputTime.pointee.mHostTime
            let pts = host != 0
                ? CMClockMakeHostTimeFromSystemUnits(host)
                : CMClockGetTime(CMClockGetHostTimeClock())
            self.handle(copy, pts: pts)
        }
        guard status == noErr, let procID else { throw RecorderError.coreAudio("No se pudo preparar la captura", status) }
        ioProcID = procID

        status = AudioDeviceStart(agg, procID)
        guard status == noErr else { throw RecorderError.coreAudio("No se pudo iniciar la captura", status) }
    }

    /// Copia los buffers del tap a un buffer estándar (float32, canales separados).
    /// El tap suele llegar entrelazado y, si la salida tiene entradas, sus buffers vienen antes en la lista.
    static func standardBuffer(from inputData: UnsafePointer<AudioBufferList>, tapFormat format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.commonFormat == .pcmFormatFloat32 else { return nil }
        let channels = Int(format.channelCount)
        guard channels > 0,
              let standard = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(channels))
        else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let needed = format.isInterleaved ? 1 : channels
        guard list.count >= needed else { return nil }
        let tapBuffers = Array(list.suffix(needed))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = Int(tapBuffers[0].mDataByteSize) / bytesPerFrame
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: standard, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)

        if format.isInterleaved {
            guard let raw = tapBuffers[0].mData else { return nil }
            let src = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<channels {
                let d = dst[c]
                for i in 0..<frames { d[i] = src[i * channels + c] }
            }
        } else {
            for c in 0..<channels {
                guard let raw = tapBuffers[c].mData else { continue }
                memcpy(dst[c], raw, min(Int(tapBuffers[c].mDataByteSize), frames * MemoryLayout<Float>.size))
            }
        }
        return out
    }

    private func teardownTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func ownAudioProcessObject() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Detiene la captura y cierra el archivo. Devuelve los frames escritos.
    @discardableResult
    func stop() async -> AVAudioFramePosition {
        silenceTimer?.cancel()
        silenceTimer = nil
        teardownTap()
        return queue.sync {
            // Conserva una pequeña cola del silencio final.
            if triggered {
                var kept = 0.0
                for (buffer, pts) in pendingSilence {
                    if kept >= Self.silenceTailSeconds { break }
                    write(buffer, pts: pts)
                    kept += Double(buffer.frameLength) / buffer.format.sampleRate
                }
            }
            pendingSilence = []
            preroll = []
            let frames = framesWritten
            file = nil // cierra el archivo
            return frames
        }
    }

    /// Lógica de disparo / silencio. Separada para poder probarla sin ScreenCaptureKit.
    func handle(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        let level = Self.peak(of: buffer)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        let threshold = pow(10, options.thresholdDB / 20)
        let loud = level >= threshold

        if !triggered {
            if options.waitForAudio && !loud {
                preroll.append((buffer, pts))
                var total = preroll.reduce(0.0) { $0 + Double($1.0.frameLength) / $1.0.format.sampleRate }
                while total > Self.prerollSeconds, preroll.count > 1 {
                    let first = preroll.removeFirst().0
                    total -= Double(first.frameLength) / first.format.sampleRate
                }
                return
            }
            triggered = true
            lastLoudPTS = pts
            for (b, p) in preroll { write(b, pts: p) }
            preroll = []
            let sr = buffer.format.sampleRate
            DispatchQueue.main.async { [weak self] in self?.onTriggered?(sr) }
        }

        if loud {
            lastLoudPTS = pts
            for (b, p) in pendingSilence { write(b, pts: p) }
            pendingSilence = []
            write(buffer, pts: pts)
        } else if options.autoStopSeconds != nil {
            // Guardamos el silencio aparte: si vuelve a sonar algo se escribe; si no, se descarta.
            pendingSilence.append((buffer, pts))
        } else {
            write(buffer, pts: pts)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        let sampleRate = buffer.format.sampleRate
        do {
            if file == nil, let url {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                firstPTS = pts
            }
            guard let file else { return }

            // El tap entrega audio continuo (también el silencio), así que se escribe tal cual:
            // no hay que rellenar huecos.
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            emitPeaks(for: buffer)
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onStopWithError?(error) }
        }
    }

    private func startSilenceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, self.triggered, !self.autoStopFired,
                  let limit = self.options.autoStopSeconds, let last = self.lastLoudPTS else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if CMTimeGetSeconds(CMTimeSubtract(now, last)) >= limit {
                self.autoStopFired = true
                DispatchQueue.main.async { self.onAutoStop?() }
            }
        }
        timer.resume()
        silenceTimer = timer
    }

    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var v: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { v = max(v, abs(channels[c][i])) }
        }
        return v
    }

    private func emitPeaks(for buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var peaks: [Float] = []
        peaks.reserveCapacity(frames / Self.framesPerPeak + 1)

        for i in 0..<frames {
            var v: Float = 0
            for c in 0..<channelCount { v = max(v, abs(channels[c][i])) }
            peakAccumulator = max(peakAccumulator, v)
            peakCount += 1
            if peakCount == Self.framesPerPeak {
                peaks.append(peakAccumulator)
                peakAccumulator = 0
                peakCount = 0
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onPeaks?(peaks) }
    }

    // MARK: - Pruebas

    /// Prepara el grabador sin ScreenCaptureKit (para pruebas de la lógica de disparo).
    func prepareForTesting(url: URL, options: RecordingOptions) {
        queue.sync {
            self.options = options
            self.url = url
            self.triggered = false
        }
    }

    func handleForTesting(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        queue.sync { handle(buffer, pts: pts) }
    }
}
