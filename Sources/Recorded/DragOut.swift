import AppKit
import SwiftUI

/// Envuelve contenido SwiftUI en una vista AppKit que inicia un arrastre de archivo real
/// (NSURL en el pasteboard), compatible con Finder, Koala Sampler, DAWs, etc.
struct DragOut<Content: View>: NSViewRepresentable {
    /// Se llama al empezar el arrastre; devuelve los archivos a arrastrar (los puede crear en ese momento).
    let makeFiles: () -> [URL]
    var onClick: (() -> Void)?
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> DragHostingView<Content> {
        let view = DragHostingView(rootView: content())
        view.makeFiles = makeFiles
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: DragHostingView<Content>, context: Context) {
        view.hosting.rootView = content()
        view.makeFiles = makeFiles
        view.onClick = onClick
    }
}

final class DragHostingView<Content: View>: NSView, NSDraggingSource {
    let hosting: NSHostingView<Content>

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var makeFiles: (() -> [URL])?
    var onClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capturamos todos los eventos del ratón en esta vista.
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        dragStarted = true
        guard let urls = makeFiles?(), !urls.isEmpty else { return }

        let p = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(min(i, 6)) * 6
            item.setDraggingFrame(NSRect(x: p.x - 24 + offset, y: p.y - 24 - offset, width: 48, height: 48), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted { onClick?() }
        mouseDownEvent = nil
        dragStarted = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }
}
