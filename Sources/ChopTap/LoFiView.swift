import SwiftUI

/// Panel del efecto lo-fi: interruptor, presets y controles.
struct LoFiPanel: View {
    @EnvironmentObject var model: AppModel

    private let accent = Color(red: 1.0, green: 0.62, blue: 0.33)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.showLoFiControls {
                controls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(model.lofi.enabled ? accent.opacity(0.07) : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(model.lofi.enabled ? accent.opacity(0.4) : Theme.stroke)
        )
        .animation(.easeOut(duration: 0.15), value: model.showLoFiControls)
    }

    // MARK: Cabecera: interruptor + presets

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.setLoFiEnabled(!model.lofi.enabled) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dial.medium.fill").font(.system(size: 12, weight: .bold))
                    Text("LO-FI").font(.caption.weight(.heavy)).tracking(1.2)
                    Circle()
                        .fill(model.lofi.enabled ? accent : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .shadow(color: model.lofi.enabled ? accent : .clear, radius: 4)
                }
                .foregroundStyle(model.lofi.enabled ? accent : Theme.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(Theme.panelRaised))
            }
            .buttonStyle(PressableStyle())
            .help(model.lofi.enabled ? "Desactivar lo-fi" : "Activar lo-fi (se aplica al escuchar y al exportar)")

            if SnapshotMode.enabled {
                presetChips // el renderizador de capturas no dibuja ScrollView
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { presetChips }
            }

            Button { model.showLoFiControls.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Ajustes").font(.caption.weight(.semibold))
                    Image(systemName: model.showLoFiControls ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var presetChips: some View {
        HStack(spacing: 6) {
            ForEach(LoFiSettings.Preset.allCases.filter { $0 != .custom }) { preset in
                presetChip(preset)
            }
            if model.lofi.preset == .custom {
                chipLabel(LoFiSettings.Preset.custom.name, selected: true)
            }
        }
    }

    private func presetChip(_ preset: LoFiSettings.Preset) -> some View {
        let selected = model.lofi.enabled && model.lofi.preset == preset
        return Button { model.applyLoFiPreset(preset) } label: {
            chipLabel(preset.name, selected: selected)
        }
        .buttonStyle(PressableStyle())
        .help(preset.detail)
    }

    private func chipLabel(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(selected ? Color.black : Theme.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(selected ? accent : Color.white.opacity(0.07)))
    }

    // MARK: Controles

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], alignment: .leading, spacing: 10) {
            knob("Bits", value: (model.lofi.bits - 4) / 12,
                 text: model.lofi.bits >= 15.9 ? "16 (sin reducir)" : "\(Int(model.lofi.bits.rounded())) bits") { v in
                model.updateLoFi { $0.bits = (4 + v * 12).rounded() }
            }
            knob("Muestreo", value: log(model.lofi.sampleRate / 6_000) / log(8),
                 text: model.lofi.sampleRate >= 47_000 ? "Sin reducir" : String(format: "%.1f kHz", model.lofi.sampleRate / 1000)) { v in
                model.updateLoFi { $0.sampleRate = 6_000 * pow(8, v) }
            }
            knob("Filtro", value: log(model.lofi.filterHz / 1_000) / log(20),
                 text: model.lofi.filterHz >= 19_500 ? "Abierto" : String(format: "%.1f kHz", model.lofi.filterHz / 1000)) { v in
                model.updateLoFi { $0.filterHz = 1_000 * pow(20, v) }
            }
            knob("Compresión", value: model.lofi.compression, text: percent(model.lofi.compression)) { v in
                model.updateLoFi { $0.compression = v }
            }
            knob("Saturación", value: model.lofi.drive, text: percent(model.lofi.drive)) { v in
                model.updateLoFi { $0.drive = v }
            }
            knob("Ruido vinilo", value: model.lofi.noise, text: percent(model.lofi.noise)) { v in
                model.updateLoFi { $0.noise = v }
            }
            knob("Wow / flutter", value: model.lofi.wow, text: percent(model.lofi.wow)) { v in
                model.updateLoFi { $0.wow = v }
            }
            aliasingSwitch
        }
    }

    /// Interruptor propio (los Toggle nativos no se pueden renderizar en las capturas).
    private var aliasingSwitch: some View {
        let active = model.lofi.sampleRate < 47_000
        let on = model.lofi.aliasing
        return Button {
            model.updateLoFi { $0.aliasing.toggle() }
            model.applyLoFiToPlayback()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aliasing").font(.caption.weight(.semibold))
                    Text(active ? "Brillo metálico de los 12 bits" : "Baja el muestreo para usarlo")
                        .font(.caption2).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? accent : Color.white.opacity(0.15)).frame(width: 34, height: 20)
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: on)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .opacity(active ? 1 : 0.5)
        .help("Sin filtro antialias: las frecuencias altas se pliegan como en los samplers de 12 bits")
    }

    private func knob(_ title: String, value: Double, text: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(text).font(.caption2.monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            Slider(value: Binding(get: { min(max(value, 0), 1) }, set: set), in: 0...1) { editing in
                if !editing { model.applyLoFiToPlayback() }
            }
            .controlSize(.mini)
            .tint(accent)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}
