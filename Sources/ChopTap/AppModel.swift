import AppKit
import AVFoundation
import SwiftUI

enum RecState { case idle, armed, recording }

@MainActor
final class AppModel: ObservableObject {
    // Grabación
    @Published var recState: RecState = .idle
    @Published var level: Float = 0
    @Published var recordingStart: Date?
    @Published var errorMessage: String?
    @Published var needsPermission = false
    @Published var recordingOptions = RecordingOptions() {
        didSet { saveOptions() }
    }

    // Audio cargado
    @Published var currentURL: URL?
    /// Picos en vivo mientras se graba.
    @Published var peaks: [Float] = []
    /// Datos completos de la onda (tras grabar) para dibujarla con detalle a cualquier zoom.
    @Published var wave: WaveData?
    @Published var totalFrames: AVAudioFramePosition = 0
    @Published var sampleRate: Double = 48_000

    // Slices
    /// Posiciones de corte (segundos), ordenadas, estrictamente dentro de (0, duración).
    @Published var markers: [Double] = []
    @Published var selectedSlice: Int?

    // Vista / reproducción
    @Published var visibleRange: ClosedRange<Double> = 0...1
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    /// Loop global: al disparar un chop se repite. Si cambia mientras suena, se aplica al momento.
    @Published var loop = false {
        didSet {
            guard loop != oldValue, isPlaying, let i = playingSlice else { return }
            playSlice(i, loop: loop)
        }
    }
    /// Chop que está sonando (nil si suena la grabación desde un punto).
    @Published var playingSlice: Int?
    var loopingSlice: Int? { isPlaying && player.looping ? playingSlice : nil }

    @Published var exportOptions = AudioTools.ExportOptions()

    // Lo-fi (estilo samplers clásicos): se aplica al escuchar y al exportar
    @Published var lofi = LoFiSettings() {
        didSet {
            guard lofi != oldValue else { return }
            player.updateLoFi(lofi)   // se oye al instante, incluso mientras suena
            if let data = try? JSONEncoder().encode(lofi) { UserDefaults.standard.set(data, forKey: "lofi") }
        }
    }
    /// Panel de controles lo-fi desplegado.
    @Published var showLoFiControls = false

    let framesPerPeak = SystemAudioRecorder.framesPerPeak
    private let recorder = SystemAudioRecorder()
    private let player = ClipPlayer()
    private var timer: Timer?
    private var exportCache: [String: URL] = [:]
    private var keyMonitor: Any?
    private var maxLevelSeen: Float = 0

    /// Todo es temporal: la grabación actual y los WAV que se generan al arrastrar.
    static let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ChopTap", isDirectory: true)
    static let slicesFolder = workFolder.appendingPathComponent("Slices", isDirectory: true)

    var isRecording: Bool { recState != .idle }
    var duration: Double { Double(totalFrames) / sampleRate }
    var peaksPerSecond: Double { sampleRate / Double(framesPerPeak) }

    init() {
        try? FileManager.default.createDirectory(at: Self.slicesFolder, withIntermediateDirectories: true)
        loadOptions()

        recorder.onPeaks = { [weak self] newPeaks in
            guard let self, self.isRecording else { return }
            self.peaks.append(contentsOf: newPeaks)
            self.totalFrames = AVAudioFramePosition(self.peaks.count * self.framesPerPeak)
            self.visibleRange = 0...max(self.duration, 1)
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.isRecording else { return }
            self.level = level
            self.maxLevelSeen = max(self.maxLevelSeen, level)
        }
        recorder.onTriggered = { [weak self] sr in
            guard let self else { return }
            self.sampleRate = sr
            guard self.recState == .armed else { return }
            self.recState = .recording
            self.recordingStart = Date()
        }
        recorder.onAutoStop = { [weak self] in
            guard let self, self.recState == .recording else { return }
            Task { await self.stopRecording() }
        }
        recorder.onStopWithError = { [weak self] error in
            guard let self else { return }
            self.errorMessage = error.localizedDescription
            if self.isRecording { Task { await self.stopRecording() } }
        }
        installKeyMonitor()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUp() }
        }
    }

    // MARK: - Opciones

    private func loadOptions() {
        let d = UserDefaults.standard
        if d.object(forKey: "waitForAudio") != nil { recordingOptions.waitForAudio = d.bool(forKey: "waitForAudio") }
        if d.object(forKey: "thresholdDB") != nil { recordingOptions.thresholdDB = d.float(forKey: "thresholdDB") }
        let stop = d.double(forKey: "autoStopSeconds")
        recordingOptions.autoStopSeconds = stop > 0 ? stop : nil
        if let data = d.data(forKey: "lofi"), let saved = try? JSONDecoder().decode(LoFiSettings.self, from: data) {
            lofi = saved
        }
    }

    // MARK: - Lo-fi

    func setLoFiEnabled(_ on: Bool) {
        lofi.enabled = on
        applyLoFiToPlayback()
    }

    func applyLoFiPreset(_ preset: LoFiSettings.Preset) {
        var s = LoFiSettings.preset(preset)
        s.enabled = true
        lofi = s
        applyLoFiToPlayback()
    }

    /// Cambiar un control pasa a "Personalizado".
    func updateLoFi(_ change: (inout LoFiSettings) -> Void) {
        var s = lofi
        change(&s)
        s.preset = .custom
        s.enabled = true
        lofi = s
    }

    /// El reproductor aplica el lo-fi en tiempo real: los cambios se oyen al instante sin reiniciar.
    func applyLoFiToPlayback() {
        player.updateLoFi(lofi)
    }

    private func saveOptions() {
        let d = UserDefaults.standard
        d.set(recordingOptions.waitForAudio, forKey: "waitForAudio")
        d.set(recordingOptions.thresholdDB, forKey: "thresholdDB")
        d.set(recordingOptions.autoStopSeconds ?? 0, forKey: "autoStopSeconds")
    }

    // MARK: - Grabación

    func toggleRecording() {
        Task {
            if isRecording { await stopRecording() } else { await startRecording() }
        }
    }

    func startRecording() async {
        stopPlayback()
        errorMessage = nil
        // Cada grabación sustituye a la anterior.
        if let old = currentURL { try? FileManager.default.removeItem(at: old) }
        let url = Self.workFolder.appendingPathComponent("grabacion-\(UUID().uuidString.prefix(8)).caf")

        peaks = []
        wave = nil
        totalFrames = 0
        markers = []
        selectedSlice = nil
        playhead = 0
        visibleRange = 0...1
        currentURL = url
        exportCache = [:]

        do {
            try await recorder.start(writingTo: url, options: recordingOptions)
            needsPermission = false
            maxLevelSeen = 0
            // Sin permiso, macOS entrega silencio absoluto en vez de un error.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.isRecording, self.maxLevelSeen == 0 else { return }
                self.needsPermission = true
                self.errorMessage = "No llega nada de audio. Si está sonando algo, activa ChopTap en Ajustes → Privacidad y seguridad → Grabación de pantalla y audio del sistema → \"Solo grabación de audio del sistema\", y reabre la app."
            }
            if recordingOptions.waitForAudio {
                recState = .armed
            } else {
                recState = .recording
                recordingStart = Date()
            }
        } catch {
            recState = .idle
            currentURL = nil
            needsPermission = true
            errorMessage = "No se pudo iniciar la grabación: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        let wasArmedOnly = recState == .armed
        recState = .idle
        recordingStart = nil
        level = 0
        await recorder.stop()
        if let url = currentURL {
            if FileManager.default.fileExists(atPath: url.path) {
                load(url)
            } else {
                currentURL = nil
                peaks = []
                wave = nil
                        totalFrames = 0
                if !wasArmedOnly {
                    errorMessage = "No se grabó nada: no sonó ningún audio mientras grababas."
                }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Carga

    func load(_ url: URL) {
        guard !isRecording else { return }
        stopPlayback()
        currentURL = url
        markers = []
        selectedSlice = nil
        playhead = 0
        exportCache = [:]
        Task.detached(priority: .userInitiated) {
            do {
                let result = try WaveData(url: url)
                await MainActor.run {
                    guard self.currentURL == url else { return }
                    self.wave = result
                    self.peaks = []
                    self.totalFrames = AVAudioFramePosition(result.frameCount)
                    self.sampleRate = result.sampleRate
                    self.visibleRange = 0...max(self.duration, 0.01)
                    self.selectedSlice = 0
                }
            } catch {
                await MainActor.run { self.errorMessage = "No se pudo abrir el audio: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Slices

    var slices: [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        let edges = [0] + markers + [duration]
        return (0..<(edges.count - 1)).map { edges[$0]...edges[$0 + 1] }
    }

    func sliceIndex(at t: Double) -> Int {
        markers.firstIndex { t < $0 } ?? markers.count
    }

    private let minSliceLength = 0.01

    func addMarker(at t: Double) {
        guard duration > 0, t > minSliceLength, t < duration - minSliceLength else { return }
        if markers.contains(where: { abs($0 - t) < minSliceLength }) { return }
        markers.append(t)
        markers.sort()
        selectedSlice = sliceIndex(at: t)
    }

    /// Corta donde está el cursor. Funciona también mientras suena: ve pulsando C al ritmo.
    func addMarkerAtPlayhead() {
        let wasPlaying = isPlaying
        addMarker(at: playhead)
        if wasPlaying { selectedSlice = sliceIndex(at: playhead) }
    }

    /// Clic en la onda: reproducir desde ahí hasta el final (para ir cortando de oído).
    func playFrom(_ t: Double) {
        playhead = t
        selectedSlice = sliceIndex(at: t)
        play(from: t, to: duration, loop: false)
    }

    func removeMarker(_ index: Int) {
        guard markers.indices.contains(index) else { return }
        markers.remove(at: index)
        if let sel = selectedSlice { selectedSlice = min(sel, markers.count) }
    }

    /// Une la slice seleccionada con la anterior (borra su marcador de inicio).
    func mergeSelectedWithPrevious() {
        guard let sel = selectedSlice, sel > 0 else { return }
        removeMarker(sel - 1)
        selectedSlice = sel - 1
    }

    /// Mueve el corte de inicio de la slice seleccionada (⌥← / ⌥→).
    func nudgeSelectedMarker(by seconds: Double) {
        guard let sel = selectedSlice, sel > 0, markers.indices.contains(sel - 1) else { return }
        stopPlayback()
        moveMarker(sel - 1, to: markers[sel - 1] + seconds)
        playhead = markers[sel - 1]
    }

    func moveMarker(_ index: Int, to t: Double) {
        guard markers.indices.contains(index) else { return }
        let lower = (index > 0 ? markers[index - 1] : 0) + minSliceLength
        let upper = (index < markers.count - 1 ? markers[index + 1] : duration) - minSliceLength
        guard lower < upper else { return }
        markers[index] = min(max(t, lower), upper)
    }

    func clearMarkers() {
        markers = []
        selectedSlice = duration > 0 ? 0 : nil
    }

    func selectSlice(_ index: Int, play shouldPlay: Bool = true) {
        guard slices.indices.contains(index) else { return }
        selectedSlice = index
        playhead = slices[index].lowerBound
        if shouldPlay { playSlice(index) }
    }

    func selectNext(_ delta: Int) {
        guard !slices.isEmpty else { return }
        let current = selectedSlice ?? (delta > 0 ? -1 : slices.count)
        selectSlice(min(max(current + delta, 0), slices.count - 1))
    }

    // MARK: - Zoom

    /// Zoom mínimo visible (segundos en pantalla).
    private let minVisibleSpan = 0.005

    func zoom(by factor: Double, around center: Double? = nil) {
        guard duration > 0 else { return }
        let span = visibleRange.upperBound - visibleRange.lowerBound
        let c = center ?? (visibleRange.lowerBound + span / 2)
        zoom(by: factor, anchor: c, fraction: (c - visibleRange.lowerBound) / max(span, 0.000001))
    }

    /// Zoom manteniendo `anchor` (segundos) en la misma posición relativa `fraction` (0…1) de la vista.
    /// Al alejar se detiene en la vista completa (zoom por defecto).
    func zoom(by factor: Double, anchor: Double, fraction: Double) {
        guard duration > 0, factor > 0 else { return }
        let span = visibleRange.upperBound - visibleRange.lowerBound
        let newSpan = min(duration, max(minVisibleSpan, span * factor))
        setVisible(start: anchor - min(max(fraction, 0), 1) * newSpan, span: newSpan)
    }

    /// Desplaza la vista `seconds` (positivo = hacia la derecha).
    func pan(by seconds: Double) {
        scrollVisible(toStart: visibleRange.lowerBound + seconds)
    }

    var zoomFactor: Double {
        let span = visibleRange.upperBound - visibleRange.lowerBound
        return duration > 0 ? duration / max(span, 0.000001) : 1
    }

    func zoomToSelection() {
        guard let sel = selectedSlice, slices.indices.contains(sel) else { return }
        let r = slices[sel]
        let span = r.upperBound - r.lowerBound
        setVisible(start: r.lowerBound - span * 0.1, span: span * 1.2)
    }

    func showAll() { visibleRange = 0...max(duration, 0.01) }

    func scrollVisible(toStart start: Double) {
        setVisible(start: start, span: visibleRange.upperBound - visibleRange.lowerBound)
    }

    private func setVisible(start: Double, span: Double) {
        let span = min(span, max(duration, 0.01))
        let s = min(max(0, start), max(0, duration - span))
        visibleRange = s...(s + span)
    }

    // MARK: - Reproducción

    func togglePlayback() {
        if isPlaying { stopPlayback() } else { play(from: playhead >= duration - 0.01 ? 0 : playhead, to: duration, loop: false) }
    }

    func playSlice(_ index: Int, loop forceLoop: Bool? = nil) {
        guard slices.indices.contains(index) else { return }
        let r = slices[index]
        play(from: r.lowerBound, to: r.upperBound, loop: forceLoop ?? loop)
        playingSlice = isPlaying ? index : nil
    }

    /// Botón de loop de un pad / tecla L: repite ese chop sin cortes, o lo para si ya está en bucle.
    func toggleSliceLoop(_ index: Int) {
        guard slices.indices.contains(index) else { return }
        if loopingSlice == index {
            stopPlayback()
        } else {
            selectedSlice = index
            playSlice(index, loop: true)
        }
    }

    func play(from start: Double, to end: Double, loop: Bool) {
        guard let url = currentURL, !isRecording, totalFrames > 0, end > start else { return }
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let count = AVAudioFrameCount(max(1, (end - start) * sampleRate))
        playingSlice = nil
        do {
            let buffer = try AudioTools.read(url, from: startFrame, count: count)
            try player.play(buffer, startSeconds: start, loop: loop, lofi: lofi, seed: UInt64(max(0, startFrame)))
            isPlaying = true
            playhead = start
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            errorMessage = "No se pudo reproducir: \(error.localizedDescription)"
        }
    }

    private func tick() {
        guard isPlaying else { return }
        guard let elapsed = player.elapsed else {
            if !player.isPlaying { stopPlayback() }
            return
        }
        if player.looping {
            playhead = player.startSeconds + elapsed.truncatingRemainder(dividingBy: max(player.lengthSeconds, 0.001))
        } else if elapsed >= player.lengthSeconds {
            playhead = player.startSeconds + player.lengthSeconds
            stopPlayback()
        } else {
            playhead = player.startSeconds + elapsed
        }
        if !player.looping, player.lengthSeconds > 0 {
            let idx = sliceIndex(at: playhead)
            if idx != selectedSlice, slices.count > 1, (player.startSeconds + player.lengthSeconds) >= duration - 0.001 {
                selectedSlice = idx
            }
        }
    }

    func stopPlayback() {
        player.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        playingSlice = nil
    }

    // MARK: - Exportar

    var canExport: Bool { currentURL != nil && !isRecording && !slices.isEmpty }

    /// Exporta una slice a WAV en la carpeta de clips (reutiliza el archivo si nada cambió).
    func exportSlice(_ index: Int) -> URL? {
        guard canExport, let url = currentURL, slices.indices.contains(index) else { return nil }
        let r = slices[index]
        let startFrame = AVAudioFramePosition(r.lowerBound * sampleRate)
        let count = AVAudioFrameCount((r.upperBound - r.lowerBound) * sampleRate)
        let key = "\(url.path)|\(startFrame)|\(count)|\(exportOptions.hashValue)|\(lofi.cacheKey)"
        if let cached = exportCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let stamp = Self.stampFormatter.string(from: Date())
        let suffix = lofi.enabled ? " LoFi" : ""
        let name = String(format: "Chop %02d%@ %@-%03d.wav", index + 1, suffix, stamp, Int(r.lowerBound * 1000) % 1000)
        let dest = Self.slicesFolder.appendingPathComponent(name)
        do {
            let lofi = self.lofi
            try AudioTools.exportWAV(from: url, start: startFrame, count: count, to: dest, options: exportOptions,
                                     transform: lofi.enabled ? { LoFi.process($0, settings: lofi, seed: UInt64(max(0, startFrame))) } : nil)
            exportCache[key] = dest
            return dest
        } catch {
            errorMessage = "No se pudo exportar: \(error.localizedDescription)"
            return nil
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()

    func exportAllSlices() -> [URL] {
        slices.indices.compactMap { exportSlice($0) }
    }

    func exportForDrag(_ index: Int) -> [URL] {
        exportSlice(index).map { [$0] } ?? []
    }

    /// Al salir se borra la grabación. Los chops exportados se dejan en la carpeta temporal
    /// (macOS la limpia sola) por si la app destino los referencia en vez de copiarlos.
    func cleanUp() {
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Teclado (estilo Slicex)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // No interceptar si se está escribiendo en un campo de texto.
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods == .option, self.handleNudge(event) { return nil }
            guard mods.isEmpty else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// ⌥← / ⌥→ mueven el corte de la slice seleccionada 10 ms (con ⇧, 1 ms).
    private func handleNudge(_ event: NSEvent) -> Bool {
        guard !isRecording, duration > 0 else { return false }
        let step = event.modifierFlags.contains(.shift) ? 0.001 : 0.01
        switch event.keyCode {
        case 123: nudgeSelectedMarker(by: -step); return true
        case 124: nudgeSelectedMarker(by: step); return true
        default: return false
        }
    }

    /// 1-9 y 0 disparan las slices 1-10; ← → navegan; C corta en el cursor; ⌫ une con la anterior; Esc para.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !isRecording, duration > 0 else { return false }
        switch event.keyCode {
        case 123: selectNext(-1); return true // ←
        case 124: selectNext(1); return true  // →
        case 51, 117: mergeSelectedWithPrevious(); return true // ⌫ / Supr
        case 53: stopPlayback(); return true // Esc
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return false }
        if ch == "c" { addMarkerAtPlayhead(); return true }
        if ch == "l" { toggleSliceLoop(selectedSlice ?? 0); return true }
        if let digit = Int(ch) {
            selectSlice(digit == 0 ? 9 : digit - 1)
            return true
        }
        return false
    }
}
