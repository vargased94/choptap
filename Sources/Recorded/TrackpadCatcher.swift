import AppKit
import SwiftUI

/// Captura el pellizco (magnify) y el desplazamiento con dos dedos / rueda sobre su área,
/// sin bloquear los clics (no participa en el hit-testing).
struct TrackpadCatcher: NSViewRepresentable {
    /// Pellizco: `magnification` incremental (positivo = acercar) y posición x en la vista.
    var onMagnify: (CGFloat, CGFloat) -> Void
    /// Scroll: deltas x/y, si es de trackpad (preciso), modificadores y posición x en la vista.
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ precise: Bool, _ flags: NSEvent.ModifierFlags, _ x: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onMagnify = onMagnify
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        var onScroll: ((CGFloat, CGFloat, Bool, NSEvent.ModifierFlags, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                switch event.type {
                case .magnify:
                    self.onMagnify?(event.magnification, p.x)
                case .scrollWheel:
                    var dx = event.scrollingDeltaX
                    var dy = event.scrollingDeltaY
                    if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 } // rueda de ratón
                    self.onScroll?(dx, dy, event.hasPreciseScrollingDeltas, event.modifierFlags, p.x)
                default:
                    return event
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
