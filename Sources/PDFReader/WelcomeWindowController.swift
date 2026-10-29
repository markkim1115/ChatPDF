import AppKit

final class WelcomeWindowController: NSWindowController {
    private let recentStack = NSStackView()
    private var recentURLs: [URL] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PDF Reader"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.center()
        let content = DropView()
        window.contentView = content

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 54, weight: .light)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "PDF Reader")
        title.font = .systemFont(ofSize: 32, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "읽기는 편안하게. 복사는 매끄럽게.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        let open = NSButton(title: "PDF 열기…", target: NSApp.delegate, action: #selector(AppDelegate.openDocument(_:)))
        open.bezelStyle = .rounded
        open.controlSize = .large
        open.keyEquivalent = "\r"
        let drop = NSTextField(labelWithString: "또는 PDF 파일을 이곳에 놓으세요")
        drop.font = .systemFont(ofSize: 11)
        drop.textColor = .tertiaryLabelColor
        let hero = NSStackView(views: [icon, title, subtitle, open, drop])
        hero.orientation = .vertical
        hero.spacing = 13
        hero.setCustomSpacing(8, after: title)
        hero.setCustomSpacing(26, after: subtitle)
        hero.setCustomSpacing(8, after: open)
        content.addSubview(hero)
        hero.translatesAutoresizingMaskIntoConstraints = false
        open.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let feature = NSStackView(views: [badge("text.alignleft", "⌘C 줄바꿈 보정"), badge("highlighter", "컬러 형광펜"), badge("doc.viewfinder", "선명한 PDF")])
        feature.spacing = 27
        content.addSubview(feature)
        feature.translatesAutoresizingMaskIntoConstraints = false
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 7
        content.addSubview(recentStack)
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        let sample = NSButton(title: "예제 문서로 복사 기능 살펴보기 →", target: self, action: #selector(openExample(_:)))
        sample.isBordered = false
        sample.font = .systemFont(ofSize: 12)
        sample.contentTintColor = .controlAccentColor
        content.addSubview(sample)
        sample.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            hero.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            feature.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 32),
            feature.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            recentStack.topAnchor.constraint(equalTo: feature.bottomAnchor, constant: 32),
            recentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 150),
            recentStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -70),
            sample.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sample.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -23)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshRecents() {
        recentStack.arrangedSubviews.forEach { recentStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        recentURLs = Array(NSDocumentController.shared.recentDocumentURLs.prefix(3))
        if !recentURLs.isEmpty {
            let title = NSTextField(labelWithString: "최근 문서")
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.textColor = .tertiaryLabelColor
            recentStack.addArrangedSubview(title)
        }
        for (index, url) in recentURLs.enumerated() {
            let button = NSButton(title: url.deletingPathExtension().lastPathComponent, target: self, action: #selector(openRecent(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = url.path
            recentStack.addArrangedSubview(button)
        }
    }
    @objc private func openRecent(_ sender: NSButton) { AppDelegate.open(recentURLs[sender.tag]) }
    @objc private func openExample(_ sender: Any?) {
        guard let source = Bundle.main.url(forResource: "Reading Guide", withExtension: "pdf") else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("PDF Reader Example \(UUID().uuidString.prefix(6)).pdf")
        do { try FileManager.default.copyItem(at: source, to: destination); AppDelegate.open(destination) }
        catch { NSApp.presentError(error) }
    }
    private func badge(_ symbol: String, _ title: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        return stack
    }
}

private final class DropView: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        files.forEach(AppDelegate.open)
        return !files.isEmpty
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
