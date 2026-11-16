// Genera el icono de ChopTap (1024×1024 PNG).
// Uso: swiftc -parse-as-library tools/icon/make-icon.swift -o /tmp/make-icon && /tmp/make-icon salida.png
import AppKit
import SwiftUI

private let palette: [Color] = [
    Color(red: 0.36, green: 0.78, blue: 1.00),
    Color(red: 0.62, green: 0.55, blue: 1.00),
    Color(red: 1.00, green: 0.45, blue: 0.70),
    Color(red: 1.00, green: 0.62, blue: 0.33),
]
private let recordRed = Color(red: 1.0, green: 0.27, blue: 0.33)

struct IconView: View {
    // Envolvente de la onda (0…1), con forma de frase musical: ataque, cuerpo, golpes y cola.
    private let bars: [CGFloat] = {
        let n = 23
        return (0..<n).map { i in
            let x = Double(i) / Double(n - 1)
            let envelope = pow(sin(x * .pi), 0.7) * 0.9 + 0.1
            // Golpes: barras altas alternadas con barras cortas, como una onda con ritmo
            let rhythm = 0.42 + 0.58 * abs(sin(Double(i) * 1.9 + 0.4))
            return CGFloat(max(0.12, min(1, envelope * rhythm)))
        }
    }()
    // Cortes entre las barras (índices de barra donde empieza cada nuevo chop).
    private let cuts = [6, 12, 18]

    var body: some View {
        ZStack {
            // Cuerpo del icono (rejilla de macOS: 824 pt dentro de 1024)
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.30),
                                            Color(red: 0.06, green: 0.05, blue: 0.11)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RadialGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.45), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.55), startRadius: 10, endRadius: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
                )
                .overlay(
                    // Brillo superior tipo cristal
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                             startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            // Onda troceada
            waveform
                .frame(width: 600, height: 380)
                .offset(y: 46)

            // Punto de grabación
            ZStack {
                Circle().fill(recordRed.opacity(0.28)).frame(width: 150, height: 150).blur(radius: 18)
                Circle().strokeBorder(recordRed.opacity(0.55), lineWidth: 7).frame(width: 118, height: 118)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.58), recordRed],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: 50))
                    .frame(width: 80, height: 80)
            }
            .offset(x: 262, y: -262)
        }
        .frame(width: 1024, height: 1024)
    }

    private var waveform: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = w / CGFloat(bars.count)
            let barW = step * 0.56
            ZStack(alignment: .topLeading) {
                ForEach(bars.indices, id: \.self) { i in
                    let seg = cuts.filter { i >= $0 }.count
                    let color = palette[seg % palette.count]
                    let bh = max(barW, bars[i] * h)
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .frame(width: barW, height: bh)
                        .shadow(color: color.opacity(0.55), radius: 14)
                        .position(x: step * (CGFloat(i) + 0.5), y: h / 2)
                }
                // Marcadores de corte con su pestaña
                ForEach(cuts.indices, id: \.self) { k in
                    let x = step * CGFloat(cuts[k])
                    let color = palette[(k + 1) % palette.count]
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 7, height: h + 70)
                        .position(x: x, y: h / 2)
                    UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous)
                        .fill(color)
                        .frame(width: 44, height: 40)
                        .overlay(
                            Text("\(k + 2)")
                                .font(.system(size: 28, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.78))
                        )
                        .position(x: x + 22, y: -35 + 20)
                }
            }
        }
    }
}

@main
struct MakeIcon {
    @MainActor static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
        let renderer = ImageRenderer(content: IconView())
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("render falló") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png falló") }
        try! png.write(to: URL(fileURLWithPath: out))
        print("Icono:", out, cg.width, "x", cg.height)
    }
}
