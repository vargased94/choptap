import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private var hasAudio: Bool { model.duration > 0 && !model.isRecording }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 14) {
                TopBar()
                if let message = model.errorMessage {
                    ErrorBanner(message: message)
                }
                if model.duration == 0 && !model.isRecording {
                    EmptyStateView()
                } else {
                    waveformArea
                    TransportBar()
                    PadsSection()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 34) // espacio para los botones de la ventana
            .padding(.bottom, 18)
        }
        .frame(minWidth: 560, minHeight: 520)
        .foregroundStyle(Theme.text)
    }

    private var waveformArea: some View {
        VStack(spacing: 6) {
            ZStack {
                WaveformView(model: model)
                if model.recState == .armed {
                    VStack(spacing: 8) {
                        Image(systemName: "ear.badge.waveform")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.playhead)
                            .symbolEffect(.pulse)
                        Text("Esperando audio…").font(.title3.weight(.semibold))
                        Text("Empezará a grabar en cuanto suene algo en el Mac")
                            .font(.callout).foregroundStyle(Theme.textDim)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .layoutPriority(1)

            if hasAudio {
                OverviewBar(model: model)
            }
        }
    }
}

// MARK: - Barra superior

struct TopBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            RecordButton()
            status
            Spacer(minLength: 8)
            VocalButton()
            SettingsMenu()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.recState {
        case .armed:
            VStack(alignment: .leading, spacing: 5) {
                Text("ARMADO").font(.caption.weight(.heavy)).foregroundStyle(Theme.playhead).tracking(1.5)
                LevelMeter(level: model.level, thresholdDB: model.recordingOptions.thresholdDB)
                    .frame(maxWidth: 220).frame(height: 6)
            }
        case .recording:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.record).frame(width: 8, height: 8)
                        .symbolEffect(.pulse)
                    if let start = model.recordingStart {
                        TimelineView(.periodic(from: start, by: 0.25)) { ctx in
                            Text(formatTime(ctx.date.timeIntervalSince(start), precise: false))
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                        }
                    }
                    if let stop = model.recordingOptions.autoStopSeconds {
                        Text("· para tras \(Int(stop)) s de silencio")
                            .font(.caption).foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                }
                LevelMeter(level: model.level, thresholdDB: model.recordingOptions.thresholdDB)
                    .frame(maxWidth: 220).frame(height: 6)
            }
        case .idle:
            if model.duration > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grabación").font(.headline)
                    Text("\(formatTime(model.duration)) · \(model.slices.count) \(model.slices.count == 1 ? "chop" : "chops")")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recorded").font(.title3.weight(.bold))
                    Text("Graba el audio del Mac y córtalo").font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

/// Quitar la voz (Demucs). Alterna original / instrumental y muestra el progreso.
struct VocalButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.duration > 0 && !model.isRecording {
            switch model.separation {
            case .running(let message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message).font(.caption.weight(.semibold)).lineLimit(1)
                        if let start = model.separationStart {
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Text("\(Int(ctx.date.timeIntervalSince(start))) s")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                    Button { model.cancelSeparation() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textDim)
                        .help("Cancelar")
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Capsule().fill(Theme.panelRaised))
            case .noVocals:
                pill(icon: "music.note", text: "Sin voz", active: false)
                    .opacity(0.6)
                    .help("Esta grabación no tiene voz: se mantiene el audio original")
            default:
                let instrumental = model.stemMode == .instrumental
                Button { model.toggleInstrumental() } label: {
                    pill(icon: instrumental ? "music.note" : "mic.slash.fill",
                         text: instrumental ? "Instrumental" : "Quitar voz",
                         active: instrumental)
                }
                .buttonStyle(PressableStyle())
                .help(instrumental
                      ? "Escuchando el instrumental · clic para volver al original"
                      : "Separa la voz con IA (Demucs) y deja solo el instrumental")
            }
        }
    }

    private func pill(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(active ? Color.black : Theme.text)
        .padding(.horizontal, 12).frame(height: 36)
        .background(Capsule().fill(active ? Theme.slice(5) : Theme.panelRaised))
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button(action: model.toggleRecording) {
            ZStack {
                Circle()
                    .fill(Theme.panelRaised)
                Circle()
                    .strokeBorder(model.recState == .armed ? Theme.playhead : Theme.record.opacity(0.5), lineWidth: 2)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(model.recState == .armed ? Theme.playhead : Theme.record)
                        .frame(width: 16, height: 16)
                } else {
                    Circle().fill(Theme.record).frame(width: 22, height: 22)
                        .shadow(color: Theme.record.opacity(0.6), radius: 6)
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut("r", modifiers: .command)
        .help(model.isRecording ? "Detener (⌘R)" : "Grabar (⌘R)")
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Section("Grabación") {
                Toggle("Empezar al detectar audio", isOn: $model.recordingOptions.waitForAudio)
                Picker("Umbral de detección", selection: $model.recordingOptions.thresholdDB) {
                    ForEach([Float(-60), -50, -40, -30, -20], id: \.self) { db in
                        Text("\(Int(db)) dB").tag(db)
                    }
                }
                Picker("Parar tras silencio", selection: Binding(
                    get: { model.recordingOptions.autoStopSeconds ?? 0 },
                    set: { model.recordingOptions.autoStopSeconds = $0 > 0 ? $0 : nil }
                )) {
                    Text("Nunca").tag(0.0)
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { s in
                        Text("\(Int(s)) s").tag(s)
                    }
                }
            }
            Section("Exportar chops (WAV)") {
                Toggle("Normalizar a -0.3 dB", isOn: $model.exportOptions.normalize)
                Picker("Fade en los bordes", selection: $model.exportOptions.fadeMs) {
                    Text("Sin fade").tag(0.0)
                    Text("2 ms").tag(2.0)
                    Text("5 ms").tag(5.0)
                    Text("20 ms").tag(20.0)
                }
                Picker("Resolución", selection: $model.exportOptions.bitDepth) {
                    Text("16 bit").tag(16)
                    Text("24 bit").tag(24)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.panelRaised))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isRecording)
        .help("Ajustes")
    }
}

// MARK: - Estado vacío

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accent.opacity(0.08)).frame(width: 130, height: 130)
                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accent, Theme.slice(2)], startPoint: .leading, endPoint: .trailing)
                    )
            }
            VStack(spacing: 6) {
                Text("Pulsa grabar y reproduce algo").font(.title2.weight(.semibold))
                Text(model.recordingOptions.waitForAudio
                     ? "La grabación empieza sola cuando detecta audio en el Mac."
                     : "Se grabará todo lo que suene en el Mac.")
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
            Button(action: model.toggleRecording) {
                Label("Grabar", systemImage: "record.circle")
                    .font(.headline)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.record))
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            Spacer()
            ShortcutHints()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
    }
}

struct ShortcutHints: View {
    private let items: [(String, String)] = [
        ("Clic", "oír desde ahí"), ("Doble clic", "cortar"), ("C", "cortar al vuelo"),
        ("⌥ clic", "borrar corte"), ("1–9", "disparar chops"), ("L", "loop del chop"), ("Espacio", "play / stop"),
    ]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { key, label in
                HStack(spacing: 5) {
                    Text(key)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                    Text(label).font(.caption2).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

// MARK: - Transporte

struct TransportBar: View {
    @EnvironmentObject var model: AppModel

    private var enabled: Bool { model.duration > 0 && !model.isRecording }

    var body: some View {
        HStack(spacing: 8) {
            IconButton(systemName: model.isPlaying ? "stop.fill" : "play.fill", active: model.isPlaying) {
                model.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Reproducir / detener (espacio)")

            IconButton(systemName: "repeat", active: model.loop) { model.loop.toggle() }
                .help("Repetir el chop en bucle al dispararlo")

            Text(formatTime(model.playhead))
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.playhead)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))

            IconButton(systemName: "scissors") { model.addMarkerAtPlayhead() }
                .help("Cortar en el cursor (C) — funciona mientras suena")

            ViewThatFits(in: .horizontal) {
                Text("Clic para oír · doble clic o C para cortar · arrastra los cortes para ajustarlos")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Text("Doble clic o C para cortar")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                Color.clear.frame(width: 0)
            }

            Spacer(minLength: 4)

            IconButton(systemName: "minus.magnifyingglass") { model.zoom(by: 2) }
                .keyboardShortcut("-", modifiers: .command)
                .help("Alejar (⌘-)")
            IconButton(systemName: "plus.magnifyingglass") { model.zoom(by: 0.5) }
                .keyboardShortcut("=", modifiers: .command)
                .help("Acercar (⌘+)")
            IconButton(systemName: "arrow.left.and.right.square") { model.showAll() }
                .keyboardShortcut("0", modifiers: .command)
                .help("Ver todo (⌘0)")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Pads

struct PadsSection: View {
    @EnvironmentObject var model: AppModel

    private var enabled: Bool { model.duration > 0 && !model.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("CHOPS").font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(Theme.textDim)
                if enabled {
                    Text("\(model.slices.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                Spacer()
                if enabled && !model.markers.isEmpty {
                    Button("Quitar cortes") { model.clearMarkers() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                }
            }

            if enabled && model.markers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "scissors").foregroundStyle(Theme.accent)
                    Text("Haz doble clic en la onda (o pulsa C mientras suena) para cortar. También puedes arrastrar la grabación entera:")
                        .font(.callout).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PadView(index: 0).frame(width: 130)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            } else if enabled {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 10)], spacing: 10) {
                        DragAllPad()
                        ForEach(model.slices.indices, id: \.self) { i in
                            PadView(index: i)
                        }
                    }
                    .padding(1)
                }
                .scrollIndicators(.automatic)
                .frame(minHeight: 84, maxHeight: 200)
            }
        }
    }
}

struct PadView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let range = model.slices.indices.contains(index) ? model.slices[index] : 0...0
        let color = Theme.slice(index)
        let selected = model.selectedSlice == index
        let playing = model.playingSlice == index && model.isPlaying
        let looping = model.loopingSlice == index

        VStack(alignment: .leading, spacing: 2) {
            // Cabecera: número, loop y duración (fuera de la zona de arrastre para que el botón responda)
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                Text(String(format: "%.2fs", range.upperBound - range.lowerBound))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                Button { model.toggleSliceLoop(index) } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(looping ? Color.black : Theme.textDim)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(looping ? color : Color.white.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help(looping ? "Parar loop (L)" : "Reproducir en loop (L)")
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectSlice(index) }

            DragOut(makeFiles: { model.exportForDrag(index) }, onClick: { model.selectSlice(index) }) {
                MiniWaveform(wave: model.wave, range: range, color: color.opacity(selected ? 1 : 0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(selected ? 0.22 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(selected || looping ? 0.9 : 0.25), lineWidth: selected || looping ? 1.5 : 1)
        )
        .shadow(color: playing ? color.opacity(0.55) : .clear, radius: 8)
        .help("Clic: oír · Arrastra la onda del chop \(index + 1) a Koala, a tu DAW o al Finder")
    }
}

struct DragAllPad: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        DragOut(makeFiles: { model.exportAllSlices() }) {
            VStack(spacing: 4) {
                Image(systemName: "square.stack.3d.down.forward.fill").font(.system(size: 18))
                Text("Arrastrar todos").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .frame(height: 76)
        .help("Arrastra todos los chops a la vez")
    }
}

// MARK: - Componentes

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.playhead)
            Text(message).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.needsPermission {
                Button("Abrir Ajustes") { model.openPrivacySettings() }
                    .controlSize(.small)
            }
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.playhead.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.playhead.opacity(0.3)))
    }
}

struct IconButton: View {
    let systemName: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .foregroundStyle(active ? Color.black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.accent : Theme.panelRaised))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LevelMeter: View {
    let level: Float
    var thresholdDB: Float? = nil

    var body: some View {
        GeometryReader { geo in
            let db = 20 * log10(max(Double(level), 0.00001))
            let norm = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Color.green, Color.yellow, Theme.record],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geo.size.width * norm)
                    }
                    .animation(.linear(duration: 0.08), value: norm)
                if let thresholdDB {
                    let tn = max(0, min(1, (Double(thresholdDB) + 60) / 60))
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2)
                        .offset(x: geo.size.width * tn - 1)
                }
            }
        }
    }
}

/// Layout que coloca elementos en filas y salta de línea cuando no caben.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Centrar cada fila
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var x: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((v, s))
            x += s.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(row.count - 1, 0))
            var cx = bounds.minX + (bounds.width - rowWidth) / 2
            let h = row.map(\.1.height).max() ?? 0
            for (v, s) in row {
                v.place(at: CGPoint(x: cx, y: y), proposal: ProposedViewSize(s))
                cx += s.width + spacing
            }
            y += h + spacing
        }
    }
}
