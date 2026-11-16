import SwiftUI

// MARK: - Tema

enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let panelRaised = Color(red: 0.15, green: 0.15, blue: 0.19)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.5)
    static let record = Color(red: 1.0, green: 0.27, blue: 0.33)
    static let accent = Color(red: 0.36, green: 0.78, blue: 1.0)
    static let playhead = Color(red: 1.0, green: 0.78, blue: 0.3)

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.78, blue: 1.00),
        Color(red: 0.62, green: 0.55, blue: 1.00),
        Color(red: 1.00, green: 0.45, blue: 0.70),
        Color(red: 1.00, green: 0.62, blue: 0.33),
        Color(red: 0.98, green: 0.86, blue: 0.35),
        Color(red: 0.45, green: 0.90, blue: 0.55),
        Color(red: 0.30, green: 0.88, blue: 0.82),
        Color(red: 0.85, green: 0.55, blue: 0.95),
    ]
    static let paletteCount = palette.count
    static func slice(_ i: Int) -> Color { palette[((i % palette.count) + palette.count) % palette.count] }
}

/// Forma de onda con cortes manuales.
/// - Clic: reproducir desde ese punto (pulsa C mientras suena para cortar al vuelo).
/// - Doble clic: añadir un corte.
/// - Arrastrar un marcador: moverlo. ⌥ + clic sobre un marcador: borrarlo.
struct WaveformView: View {
    @ObservedObject var model: AppModel
    @StateObject private var ui = WaveformUIState()

    static let rulerHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(in: &ctx, size: size) }
                ruler(width: width)
                markerTabs(width: width)
                dragLabel(width: width)
                zoomBadge
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    ui.hoverX = p.x
                    ui.hoverMarker = model.isRecording ? nil : markerIndex(at: p, width: width)
                } else {
                    ui.hoverX = nil
                    ui.hoverMarker = nil
                }
                updateCursor()
            }
            .background(
                TrackpadCatcher(
                    onMagnify: { m, x in handleMagnify(m, x: x, width: width) },
                    onScroll: { dx, dy, precise, flags, x in handleScroll(dx: dx, dy: dy, precise: precise, flags: flags, x: x, width: width) }
                )
            )
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func updateCursor() {
        if ui.hoverMarker != nil || ui.draggingMarker != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Trackpad

    /// Pellizco: acercar/alejar centrado en el cursor. Al alejar se para en la vista completa.
    private func handleMagnify(_ m: CGFloat, x: CGFloat, width: CGFloat) {
        guard model.duration > 0, !model.isRecording else { return }
        let factor = exp(-Double(m) * 2.2)
        model.zoom(by: factor, anchor: time(at: x, width: width), fraction: Double(x / max(width, 1)))
    }

    /// Dos dedos en horizontal (o rueda): desplazar. Con ⌘ o ⌥: zoom.
    private func handleScroll(dx: CGFloat, dy: CGFloat, precise: Bool, flags: NSEvent.ModifierFlags, x: CGFloat, width: CGFloat) {
        guard model.duration > 0, !model.isRecording else { return }
        if flags.contains(.command) || flags.contains(.option) {
            let factor = exp(-Double(dy) * 0.012)
            model.zoom(by: factor, anchor: time(at: x, width: width), fraction: Double(x / max(width, 1)))
            return
        }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        let span = model.visibleRange.upperBound - model.visibleRange.lowerBound
        model.pan(by: -Double(delta) / Double(max(width, 1)) * span)
    }

    // MARK: - Coordenadas

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        let r = model.visibleRange
        let t = r.lowerBound + Double(x / max(width, 1)) * (r.upperBound - r.lowerBound)
        return min(max(0, t), model.duration)
    }

    private func x(at t: Double, width: CGFloat) -> CGFloat {
        let r = model.visibleRange
        return CGFloat((t - r.lowerBound) / max(r.upperBound - r.lowerBound, 0.0001)) * width
    }

    /// Marcador bajo el punto: cerca de su línea (±10 px) o sobre su pestaña numerada.
    private func markerIndex(at p: CGPoint, width: CGFloat) -> Int? {
        let tabTop = Self.rulerHeight + 4
        if p.y >= tabTop, p.y <= tabTop + 18 {
            // La pestaña de la slice i+1 empieza en el marcador i y mide ~22 px.
            for (i, m) in model.markers.enumerated().reversed() {
                let mx = x(at: m, width: width)
                if p.x >= mx - 3, p.x <= mx + 24 { return i }
            }
        }
        var best: (Int, CGFloat)?
        for (i, m) in model.markers.enumerated() {
            let d = abs(x(at: m, width: width) - p.x)
            if d < 10, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Tiempo del marcador mientras se arrastra.
    @ViewBuilder
    private func dragLabel(width: CGFloat) -> some View {
        if let i = ui.draggingMarker, model.markers.indices.contains(i) {
            let mx = x(at: model.markers[i], width: width)
            Text(formatTime(model.markers[i]))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white))
                .fixedSize()
                .offset(x: min(max(4, mx - 36), width - 80), y: 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var zoomBadge: some View {
        if !model.isRecording, model.zoomFactor > 1.05 {
            HStack {
                Spacer()
                Text(String(format: "×%.1f", model.zoomFactor))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.4)))
                    .padding(.trailing, 8)
            }
            .padding(.top, 3)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Dibujo

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let top = Self.rulerHeight
        let waveRect = CGRect(x: 0, y: top, width: width, height: size.height - top)
        let midY = waveRect.midY
        let halfH = waveRect.height / 2 - 12
        let showSlices = !model.isRecording && !model.markers.isEmpty
        let r = model.visibleRange
        let span = max(r.upperBound - r.lowerBound, 0.000001)

        // Bandas de cada slice (alternas, la seleccionada más clara), como en Slicex
        var regions: [(rect: CGRect, color: Color)] = []
        if showSlices {
            for (i, sr) in model.slices.enumerated() {
                let x0 = max(0, x(at: sr.lowerBound, width: width))
                let x1 = min(width, x(at: sr.upperBound, width: width))
                guard x1 > 0, x0 < width, x1 > x0 else { continue }
                let rect = CGRect(x: x0, y: top, width: x1 - x0, height: waveRect.height)
                let selected = i == model.selectedSlice
                ctx.fill(Path(rect), with: .color(Theme.slice(i).opacity(selected ? 0.14 : (i % 2 == 0 ? 0.035 : 0.06))))
                regions.append((rect, Theme.slice(i)))
            }
        } else {
            let color = model.isRecording ? Theme.record : Theme.slice(0)
            if !model.isRecording, model.duration > 0 {
                ctx.fill(Path(waveRect), with: .color(color.opacity(0.04)))
            }
            regions.append((waveRect, color))
        }

        // Rejilla: centro y ±50 %
        ctx.fill(Path(CGRect(x: 0, y: midY - 0.5, width: width, height: 1)), with: .color(.white.opacity(0.10)))
        for f in [-0.5, 0.5] {
            let y = midY - CGFloat(f) * halfH
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
            ctx.stroke(line, with: .color(.white.opacity(0.04)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }

        // Forma de onda
        if model.isRecording {
            let path = liveEnvelope(width: width, midY: midY, halfH: halfH)
            fillWave(path, in: &ctx, regions: regions, midY: midY, halfH: halfH)
        } else if let wave = model.wave, wave.frameCount > 0 {
            let sr = wave.sampleRate
            let samplesPerPoint = span * sr / Double(max(width, 1))
            if samplesPerPoint > 1.5 {
                // Sobre relleno (mín/máx) con el nivel de detalle que toque
                let columns = max(1, Int(width * 2))
                let path = wave.envelopePath(from: r.lowerBound, to: r.upperBound, width: width, columns: columns,
                                             midY: midY, halfHeight: halfH)
                fillWave(path, in: &ctx, regions: regions, midY: midY, halfH: halfH)
            } else {
                // Zoom extremo: dibujar las muestras reales como curva
                let f0 = max(0, Int((r.lowerBound * sr).rounded(.down)) - 1)
                let f1 = min(wave.frameCount, Int((r.upperBound * sr).rounded(.up)) + 2)
                guard f1 > f0 else { return }
                var curve = Path()
                var area = Path()
                var points: [CGPoint] = []
                points.reserveCapacity(f1 - f0)
                for f in f0..<f1 {
                    let px = CGFloat((Double(f) / sr - r.lowerBound) / span) * width
                    let py = midY - CGFloat(max(-1, min(1, wave.samples[f] * wave.displayGain))) * halfH
                    points.append(CGPoint(x: px, y: py))
                }
                if let first = points.first, let last = points.last {
                    curve.move(to: first)
                    area.move(to: CGPoint(x: first.x, y: midY))
                    area.addLine(to: first)
                    for p in points.dropFirst() { curve.addLine(to: p); area.addLine(to: p) }
                    area.addLine(to: CGPoint(x: last.x, y: midY))
                    area.closeSubpath()
                }
                for region in regions {
                    var c = ctx
                    c.clip(to: Path(region.rect))
                    c.fill(area, with: .color(region.color.opacity(0.22)))
                    c.stroke(curve, with: .color(region.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if samplesPerPoint < 0.12 {
                        for p in points {
                            c.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(region.color))
                        }
                    }
                }
            }
        }

        // Marcadores
        if !model.isRecording {
            for (i, m) in model.markers.enumerated() {
                let mx = x(at: m, width: width)
                guard mx >= -2, mx <= width + 2 else { continue }
                let active = i == ui.draggingMarker || (ui.draggingMarker == nil && i == ui.hoverMarker)
                if active {
                    ctx.fill(Path(CGRect(x: mx - 6, y: top, width: 12, height: waveRect.height)),
                             with: .color(Theme.slice(i + 1).opacity(0.18)))
                }
                let w: CGFloat = active ? 3 : 2
                ctx.fill(Path(CGRect(x: mx - w / 2, y: top, width: w, height: waveRect.height)),
                         with: .color(active ? Color.white : Theme.slice(i + 1).opacity(0.95)))
            }
        }

        // Cursor de reproducción
        if model.duration > 0, !model.isRecording {
            let px = x(at: model.playhead, width: width)
            ctx.fill(Path(CGRect(x: px - 1, y: top, width: 2, height: waveRect.height)), with: .color(Theme.playhead))
            var tri = Path()
            tri.move(to: CGPoint(x: px - 5, y: top))
            tri.addLine(to: CGPoint(x: px + 5, y: top))
            tri.addLine(to: CGPoint(x: px, y: top + 6))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Theme.playhead))
        }

        // Hover
        if let hx = ui.hoverX, !model.isRecording, model.duration > 0 {
            ctx.fill(Path(CGRect(x: hx, y: top, width: 1, height: waveRect.height)),
                     with: .color(.white.opacity(0.25)))
        }
    }

    /// Rellena el contorno con un degradado del color de cada slice y lo perfila.
    private func fillWave(_ path: Path, in ctx: inout GraphicsContext,
                          regions: [(rect: CGRect, color: Color)], midY: CGFloat, halfH: CGFloat) {
        for region in regions {
            var c = ctx
            c.clip(to: Path(region.rect))
            let gradient = Gradient(stops: [
                .init(color: region.color.opacity(0.95), location: 0),
                .init(color: region.color.opacity(0.55), location: 0.5),
                .init(color: region.color.opacity(0.95), location: 1),
            ])
            c.fill(path, with: .linearGradient(gradient,
                                               startPoint: CGPoint(x: 0, y: midY - halfH),
                                               endPoint: CGPoint(x: 0, y: midY + halfH)))
            c.stroke(path, with: .color(region.color.opacity(0.9)), lineWidth: 0.6)
        }
    }

    /// Contorno simétrico a partir de los picos que llegan mientras se graba.
    private func liveEnvelope(width: CGFloat, midY: CGFloat, halfH: CGFloat) -> Path {
        var path = Path()
        let peaks = model.peaks
        guard !peaks.isEmpty, model.sampleRate > 0 else { return path }
        let pps = model.peaksPerSecond
        let r = model.visibleRange
        let span = r.upperBound - r.lowerBound
        var tops: [CGPoint] = []
        let columns = max(1, Int(width))
        for c in 0...columns {
            let t0 = r.lowerBound + span * Double(c) / Double(columns)
            let t1 = r.lowerBound + span * Double(c + 1) / Double(columns)
            let i0 = Int(t0 * pps), i1 = max(i0 + 1, Int(t1 * pps))
            if i0 >= peaks.count { break }
            var v: Float = 0
            for i in max(0, i0)..<min(i1, peaks.count) { v = max(v, peaks[i]) }
            tops.append(CGPoint(x: width * CGFloat(c) / CGFloat(columns), y: max(CGFloat(min(v, 1)) * halfH, 0.5)))
        }
        guard let first = tops.first else { return path }
        path.move(to: CGPoint(x: first.x, y: midY - first.y))
        for p in tops.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: midY - p.y)) }
        for p in tops.reversed() { path.addLine(to: CGPoint(x: p.x, y: midY + p.y)) }
        path.closeSubpath()
        return path
    }

    /// Pestañas numeradas al inicio de cada slice.
    private func markerTabs(width: CGFloat) -> some View {
        let starts: [(Int, Double)] = (model.isRecording || model.markers.isEmpty)
            ? [] : model.slices.enumerated().map { ($0.offset, $0.element.lowerBound) }
        return ZStack(alignment: .topLeading) {
            ForEach(starts, id: \.0) { item in
                let px = x(at: item.1, width: width)
                if px >= -30, px <= width {
                    Text("\(item.0 + 1)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(
                            UnevenRoundedRectangle(bottomTrailingRadius: 5, topTrailingRadius: 5, style: .continuous)
                                .fill(Theme.slice(item.0).opacity(item.0 == model.selectedSlice ? 1 : 0.7))
                        )
                        .offset(x: px, y: Self.rulerHeight + 4)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ruler(width: CGFloat) -> some View {
        let r = model.visibleRange
        let span = max(r.upperBound - r.lowerBound, 0.001)
        let steps: [Double] = [0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { span / $0 <= Double(width / 90) } ?? 600
        let first = (r.lowerBound / step).rounded(.up) * step
        let ticks = model.duration > 0 ? stride(from: first, through: r.upperBound, by: step).map { $0 } : []
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: Self.rulerHeight)
            ForEach(ticks, id: \.self) { t in
                Text(formatTime(t, precise: step < 1))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .offset(x: x(at: t, width: width) + 4, y: 5)
                Rectangle().fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 8)
                    .offset(x: x(at: t, width: width), y: Self.rulerHeight - 8)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestos

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !model.isRecording, model.duration > 0 else { return }
                if case .none = ui.dragMode {
                    if let i = markerIndex(at: value.startLocation, width: width) {
                        if NSEvent.modifierFlags.contains(.option) {
                            model.removeMarker(i)
                            ui.hoverMarker = nil
                            ui.dragMode = .consumed
                            return
                        }
                        ui.dragMode = .marker(i, original: model.markers[i])
                        ui.draggingMarker = i
                        model.stopPlayback()
                        NSCursor.resizeLeftRight.set()
                    } else {
                        ui.dragMode = .click
                    }
                }
                if case .marker(let i, let original) = ui.dragMode {
                    let span = model.visibleRange.upperBound - model.visibleRange.lowerBound
                    let secondsPerPoint = span / Double(max(width, 1))
                    let t: Double
                    if NSEvent.modifierFlags.contains(.shift) {
                        // Ajuste fino: 8 veces más lento
                        t = original + Double(value.translation.width) * secondsPerPoint / 8
                    } else {
                        t = time(at: value.location.x, width: width)
                    }
                    // Desplazar la vista si se arrastra hacia los bordes estando con zoom
                    if value.location.x < 18 { model.pan(by: -span * 0.015) }
                    if value.location.x > width - 18 { model.pan(by: span * 0.015) }
                    model.moveMarker(i, to: t)
                }
            }
            .onEnded { value in
                defer {
                    ui.dragMode = .none
                    ui.draggingMarker = nil
                    updateCursor()
                }
                guard !model.isRecording, model.duration > 0 else { return }
                if case .marker(let i, _) = ui.dragMode, model.markers.indices.contains(i) {
                    model.selectSlice(i + 1, play: abs(value.translation.width) > 2)
                    return
                }
                guard case .click = ui.dragMode, abs(value.translation.width) <= 3 else { return }
                let t = time(at: value.location.x, width: width)
                let now = Date()
                if let last = ui.lastClick, now.timeIntervalSince(last.date) < 0.35, abs(last.x - value.location.x) < 5 {
                    // Doble clic: cortar aquí y oír la nueva slice
                    ui.lastClick = nil
                    model.addMarker(at: t)
                    model.selectSlice(model.sliceIndex(at: t))
                } else {
                    ui.lastClick = (now, value.location.x)
                    model.playFrom(t)
                }
            }
    }
}

final class WaveformUIState: ObservableObject {
    enum DragMode { case none, click, marker(Int, original: Double), consumed }
    var dragMode: DragMode = .none
    @Published var hoverMarker: Int?
    @Published var draggingMarker: Int?
    var lastClick: (date: Date, x: CGFloat)?
    @Published var hoverX: CGFloat?
}

/// Mini forma de onda de un rango (para los pads).
struct MiniWaveform: View {
    let wave: WaveData?
    let range: ClosedRange<Double>
    var color: Color = .white

    var body: some View {
        Canvas { ctx, size in
            guard let wave, range.upperBound > range.lowerBound else { return }
            let mid = size.height / 2
            let path = wave.envelopePath(from: range.lowerBound, to: range.upperBound, width: size.width,
                                         columns: max(1, Int(size.width)), midY: mid, halfHeight: mid - 1)
            ctx.fill(path, with: .color(color))
        }
    }
}

/// Vista general de toda la grabación con la ventana visible (como la barra superior de Slicex).
/// Arrastra la ventana para desplazarte; haz clic fuera de ella para saltar; doble clic para ver todo.
struct OverviewBar: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = OverviewState()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in draw(in: &ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in drag(v, width: w) }
                        .onEnded { v in
                            state.grabOffset = nil
                            let now = Date()
                            if abs(v.translation.width) < 2 {
                                if let last = state.lastClick, now.timeIntervalSince(last) < 0.35 {
                                    model.showAll()
                                    state.lastClick = nil
                                } else {
                                    state.lastClick = now
                                }
                            }
                        }
                )
        }
        .frame(height: 34)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
        .help("Arrastra para moverte · doble clic para ver todo")
    }

    private func drag(_ v: DragGesture.Value, width: CGFloat) {
        guard model.duration > 0 else { return }
        let d = model.duration
        let span = model.visibleRange.upperBound - model.visibleRange.lowerBound
        let t = Double(v.location.x / max(width, 1)) * d
        if state.grabOffset == nil {
            let startT = Double(v.startLocation.x / max(width, 1)) * d
            if model.visibleRange.contains(startT) {
                state.grabOffset = startT - model.visibleRange.lowerBound
            } else {
                state.grabOffset = span / 2
            }
        }
        model.scrollVisible(toStart: t - (state.grabOffset ?? span / 2))
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        guard let wave = model.wave, model.duration > 0 else { return }
        let w = size.width, h = size.height
        let d = model.duration
        func px(_ t: Double) -> CGFloat { CGFloat(t / d) * w }

        if !model.markers.isEmpty {
            for (i, r) in model.slices.enumerated() {
                ctx.fill(Path(CGRect(x: px(r.lowerBound), y: 0, width: px(r.upperBound) - px(r.lowerBound), height: h)),
                         with: .color(Theme.slice(i).opacity(0.12)))
            }
        }
        let path = wave.envelopePath(from: 0, to: d, width: w, columns: max(1, Int(w)), midY: h / 2, halfHeight: h / 2 - 3)
        ctx.fill(path, with: .color(.white.opacity(0.45)))
        for m in model.markers {
            ctx.fill(Path(CGRect(x: px(m) - 0.5, y: 0, width: 1, height: h)), with: .color(.white.opacity(0.35)))
        }

        let v0 = px(model.visibleRange.lowerBound), v1 = px(model.visibleRange.upperBound)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: v0, height: h)), with: .color(.black.opacity(0.45)))
        ctx.fill(Path(CGRect(x: v1, y: 0, width: w - v1, height: h)), with: .color(.black.opacity(0.45)))
        let window = CGRect(x: v0, y: 1, width: max(4, v1 - v0), height: h - 2)
        ctx.fill(Path(roundedRect: window, cornerRadius: 5), with: .color(Theme.accent.opacity(0.10)))
        ctx.stroke(Path(roundedRect: window, cornerRadius: 5), with: .color(Theme.accent.opacity(0.9)), lineWidth: 1.5)

        let ph = px(model.playhead)
        ctx.fill(Path(CGRect(x: ph - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.playhead))
    }
}

final class OverviewState: ObservableObject {
    var grabOffset: Double?
    var lastClick: Date?
}

func formatTime(_ t: Double, precise: Bool = true) -> String {
    let t = max(0, t)
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return precise ? String(format: "%d:%06.3f", m, s) : String(format: "%d:%02d", m, Int(s))
}
