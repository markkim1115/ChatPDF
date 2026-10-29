import AppKit

final class ChatSplitView: NSSplitView {
    // Keep the entire visible strip draggable without covering either pane.
    override var dividerThickness: CGFloat { 14 }

    override func drawDivider(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let grip = NSRect(x: rect.midX - 2, y: rect.midY - 22, width: 4, height: 44)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }
}
