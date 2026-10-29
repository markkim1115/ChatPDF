import AppKit

/// Temporary region selector above PDFView. Removing it restores native PDF
/// selection immediately; no document annotations are created.
final class OCRRegionView: NSView {
    var didSelect: ((CGRect) -> Void)?
    var didCancel: (() -> Void)?
    private var anchor: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
        if selection.width >= 8, selection.height >= 8 { didSelect?(selection) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { didCancel?() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        guard !selection.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        selection.fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}
