import AppKit

final class ExpandingSearchField: NSSearchField {
    var onFocus: (() -> Void)?
    private var width: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        width = widthAnchor.constraint(equalToConstant: 150)
        width.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            width.constant = 280
            onFocus?()
        }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return can end editing without moving focus. Check after AppKit has
        // finished handing the field editor to its next control.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let editing = self.currentEditor().map { self.window?.firstResponder === $0 } ?? false
            self.width.constant = editing || self.window?.firstResponder === self ? 280 : 150
        }
    }
}
