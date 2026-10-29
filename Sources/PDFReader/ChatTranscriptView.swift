import AppKit
import PDFReaderCore

final class ChatPanelBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class ChatRoundedSurface: NSView {
    var fillColor: NSColor = .controlBackgroundColor
    var showsBorder = true
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17)
        fillColor.setFill()
        shape.fill()
        if showsBorder {
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class ChatMessageView: NSView {
    private(set) var message: ChatMessage
    private let bubble = ChatRoundedSurface()
    private let body = NSTextView()
    private let author = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    private var textScale: CGFloat

    override var isFlipped: Bool { true }

    init(message: ChatMessage, scale: CGFloat, delegate: NSTextViewDelegate?) {
        self.message = message
        textScale = scale
        super.init(frame: .zero)
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = true
        body.drawsBackground = false
        body.textContainerInset = .zero
        body.isVerticallyResizable = false
        body.isHorizontallyResizable = false
        body.textContainer?.widthTracksTextView = false
        body.textContainer?.lineFragmentPadding = 0
        body.delegate = delegate
        body.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        body.setAccessibilityLabel(message.role == "user" ? "내 질문" : message.role == "assistant" ? "ChatGPT 답변" : "대화 안내")
        author.stringValue = message.role == "user" ? "나" : message.role == "assistant" ? "ChatGPT" : "안내"
        author.font = .systemFont(ofSize: 11 * scale, weight: .medium)
        author.textColor = .secondaryLabelColor
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "메시지 복사")
        copyButton.imageScaling = .scaleProportionallyDown
        copyButton.isBordered = false
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = message.role == "user" ? "질문 복사" : "답변 복사"
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        bubble.fillColor = message.role == "user" ? .quaternaryLabelColor : .controlBackgroundColor
        bubble.showsBorder = message.role != "user"
        addSubview(author)
        addSubview(copyButton)
        addSubview(bubble)
        bubble.addSubview(body)
        body.textStorage?.setAttributedString(Self.formatted(message, scale: scale))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ message: ChatMessage, scale: CGFloat) {
        guard self.message.text != message.text || textScale != scale else { return }
        let selection = body.selectedRange()
        self.message = message
        textScale = scale
        author.font = .systemFont(ofSize: 11 * scale, weight: .medium)
        body.textStorage?.setAttributedString(Self.formatted(message, scale: scale))
        if NSMaxRange(selection) <= body.string.utf16.count { body.setSelectedRange(selection) }
        measuredWidth = -1
    }

    func arrange(width: CGFloat) -> CGFloat {
        if width == measuredWidth { return measuredHeight }
        measuredWidth = width
        let available = max(1, width - 24)
        let maximum = message.role == "user" ? available * 0.86 : available
        let padding: CGFloat = 14
        guard let container = body.textContainer, let manager = body.layoutManager else { return 0 }
        container.containerSize = NSSize(width: max(1, maximum - padding * 2), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let bubbleWidth = min(maximum, max(author.intrinsicContentSize.width + 30, 76, ceil(manager.usedRect(for: container).width) + padding * 2))
        container.containerSize.width = max(1, bubbleWidth - padding * 2)
        manager.ensureLayout(for: container)
        let textHeight = max(20, ceil(manager.usedRect(for: container).height))
        let x = message.role == "user" ? width - 12 - bubbleWidth : 12
        let authorHeight = max(17, ceil(author.intrinsicContentSize.height))
        author.frame = NSRect(x: x + 3, y: 0, width: bubbleWidth - 30, height: authorHeight)
        copyButton.frame = NSRect(x: x + bubbleWidth - 23, y: (authorHeight - 22) / 2, width: 22, height: 22)
        bubble.frame = NSRect(x: x, y: authorHeight + 6, width: bubbleWidth, height: textHeight + 24)
        body.frame = NSRect(x: padding, y: 12, width: bubbleWidth - padding * 2, height: textHeight)
        measuredHeight = bubble.frame.maxY
        return measuredHeight
    }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body.string, forType: .string)
        NSAccessibility.post(element: copyButton, notification: .announcementRequested,
                             userInfo: [.announcement: "메시지를 복사했습니다", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private static func formatted(_ message: ChatMessage, scale: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4 * scale
        paragraph.paragraphSpacing = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale),
            .foregroundColor: message.role == "notice" ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        guard message.role == "assistant",
              let markdown = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: message.text, attributes: attributes)
        }
        let result = NSMutableAttributedString()
        for run in markdown.runs {
            var style = attributes
            if let intent = run.inlinePresentationIntent {
                var font = NSFont.systemFont(ofSize: 13 * scale)
                if intent.contains(.stronglyEmphasized) { font = .boldSystemFont(ofSize: 13 * scale) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular) }
                style[.font] = font
            }
            if let link = run.link, ChatLink(url: link) != nil {
                style[.link] = link
                style[.foregroundColor] = NSColor.linkColor
            }
            result.append(NSAttributedString(string: String(markdown.characters[run.range]), attributes: style))
        }
        return result
    }
}

@MainActor
final class ChatTranscriptView: NSView {
    weak var textDelegate: NSTextViewDelegate?
    private var rows: [ChatMessageView] = []
    private var lastQuestionID: String?
    private var textScale: CGFloat = 1
    private let emptyTitle = NSTextField(wrappingLabelWithString: "PDF를 읽으며 바로 질문하세요")
    private let emptyBody = NSTextField(wrappingLabelWithString: "내용을 요약하거나 수식과 그림을 함께 살펴보세요.\n\n문장을 선택하면 질문에 함께 담깁니다.\n질문에 필요한 PDF 내용은 ChatGPT로 전송됩니다.")
    private let activity = NSTextField(labelWithString: "답변을 준비하는 중…")
    private var viewportHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        emptyTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize: 12)
        emptyBody.textColor = .secondaryLabelColor
        emptyBody.alignment = .center
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.isHidden = true
        [emptyTitle, emptyBody, activity].forEach(addSubview)
        setAccessibilityLabel("PDF 대화 내용")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct ScrollPosition {
        let atBottom: Bool
        let messageID: String?
        let offset: CGFloat
        let y: CGFloat
    }

    private func scrollPosition() -> ScrollPosition {
        let visible = enclosingScrollView?.contentView.bounds ?? .zero
        let anchor = rows.first { $0.frame.maxY > visible.minY }
        return ScrollPosition(atBottom: visible.maxY >= bounds.height - 48,
                              messageID: anchor?.message.id,
                              offset: visible.minY - (anchor?.frame.minY ?? 0), y: visible.minY)
    }

    func update(messages: [ChatMessage], isBusy: Bool) {
        let position = scrollPosition()
        let lastQuestion = messages.last(where: { $0.role == "user" })?.id
        let sentQuestion = lastQuestion != lastQuestionID && lastQuestion != nil
        lastQuestionID = lastQuestion
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.message.id, $0) })
        rows = messages.map { message in
            if let row = existing[message.id] { row.update(message, scale: textScale); return row }
            let row = ChatMessageView(message: message, scale: textScale, delegate: textDelegate)
            addSubview(row)
            return row
        }
        let ids = Set(messages.map(\.id))
        for (id, row) in existing where !ids.contains(id) { row.removeFromSuperview() }
        emptyTitle.isHidden = !messages.isEmpty
        emptyBody.isHidden = !messages.isEmpty
        activity.isHidden = !isBusy || messages.last?.role == "assistant"
        arrangeRows()
        restore(position, followBottom: sentQuestion)
    }

    func fitViewport() {
        guard let scroll = enclosingScrollView else { return }
        let size = scroll.contentSize
        guard frame.width != size.width || viewportHeight != size.height else { return }
        let position = scrollPosition()
        viewportHeight = size.height
        super.setFrameSize(NSSize(width: size.width, height: frame.height))
        arrangeRows()
        restore(position)
    }

    func setTextScale(_ scale: CGFloat) {
        guard textScale != scale else { return }
        let position = scrollPosition()
        textScale = scale
        rows.forEach { $0.update($0.message, scale: scale) }
        emptyTitle.font = .systemFont(ofSize: 15 * scale, weight: .semibold)
        emptyBody.font = .systemFont(ofSize: 12 * scale)
        activity.font = .systemFont(ofSize: 12 * scale)
        arrangeRows()
        restore(position)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let position = scrollPosition()
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged { arrangeRows(); restore(position) }
    }

    private func arrangeRows() {
        var y: CGFloat = 16
        for row in rows {
            let height = row.arrange(width: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 24
        }
        if !activity.isHidden {
            let height = max(20, ceil(activity.intrinsicContentSize.height))
            activity.frame = NSRect(x: 26, y: y, width: max(0, bounds.width - 52), height: height)
            y += height + 24
        }
        let titleWidth = max(1, bounds.width - 32)
        let bodyWidth = max(1, bounds.width - 52)
        let titleHeight = ceil(emptyTitle.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let bodyHeight = ceil(emptyBody.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: bodyWidth, height: .greatestFiniteMagnitude)).height)
        emptyTitle.frame = NSRect(x: 16, y: 65, width: titleWidth, height: titleHeight)
        emptyBody.frame = NSRect(x: 26, y: emptyTitle.frame.maxY + 14, width: bodyWidth, height: bodyHeight)
        let height = max(viewportHeight, rows.isEmpty ? emptyBody.frame.maxY + 32 : y)
        if frame.height != height { super.setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    private func restore(_ position: ScrollPosition, followBottom: Bool = false) {
        guard let scroll = enclosingScrollView else { return }
        let maximum = max(0, frame.height - scroll.contentSize.height)
        let anchor = rows.first { $0.message.id == position.messageID }
        let y = position.atBottom || followBottom ? maximum : (anchor.map { $0.frame.minY + position.offset } ?? position.y)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, y))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
