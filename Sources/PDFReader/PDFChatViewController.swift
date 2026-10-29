import AppKit
import PDFReaderCore

private final class ChatComposer: NSTextView {
    var onSend: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        // Let the input method commit marked Korean text before handling Return.
        if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onSend?()
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class PDFChatViewController: NSViewController, NSTextViewDelegate {
    var onClose: (() -> Void)?
    var onPage: ((Int) -> Void)?
    var makeContext: (() throws -> PDFChatContext)?
    private let session: PDFChatSession
    private let modelPicker = NSPopUpButton()
    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let composer = ChatComposer()
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let connectButton = NSButton(title: "연결", target: nil, action: nil)
    private let newButton = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private var renderedMessages: [String] = []
    private var renderedBusy = false
    private var documentAvailable = true
    private var renderTask: Task<Void, Never>?

    init(documentURL: URL) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Reader/Assistant", isDirectory: true)
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        session = PDFChatSession(executable: app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"),
                                 directory: support, documentURL: documentURL)
        super.init(nibName: nil, bundle: nil)
        session.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let panel = NSVisualEffectView()
        panel.material = .sidebar
        panel.blendingMode = .withinWindow
        panel.state = .followsWindowActiveState
        view = panel
        let title = NSTextField(labelWithString: "ChatGPT")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        newButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "새 대화")
        newButton.bezelStyle = .texturedRounded
        newButton.target = self; newButton.action = #selector(newConversation)
        newButton.toolTip = "새 대화 시작 · 기존 대화는 파일로 보관합니다"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "대화창 닫기")!, target: self, action: #selector(closePanel))
        close.bezelStyle = .texturedRounded
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, newButton, close])
        header.spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        modelPicker.target = self; modelPicker.action = #selector(modelChanged)
        modelPicker.font = .systemFont(ofSize: 12)
        modelPicker.setAccessibilityLabel("ChatGPT 모델")
        modelPicker.addItem(withTitle: "모델 불러오는 중…")
        connectButton.bezelStyle = .rounded
        connectButton.target = self; connectButton.action = #selector(connect)
        let modelRow = NSStackView(views: [modelPicker, connectButton])
        modelRow.spacing = 8
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.delegate = self
        transcript.textContainerInset = NSSize(width: 4, height: 14)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityLabel("PDF 대화 내용")
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.contentView.drawsBackground = false

        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        composer.isRichText = false
        composer.font = .systemFont(ofSize: 13)
        composer.textContainerInset = NSSize(width: 8, height: 8)
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.setAccessibilityLabel("PDF에 질문하기")
        composer.delegate = self
        composer.onSend = { [weak self] in
            guard let self, !self.session.isBusy else { return }
            self.send()
        }
        let inputScroll = NSScrollView()
        inputScroll.documentView = composer
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 8
        inputScroll.layer?.masksToBounds = true
        let hint = NSTextField(labelWithString: "Enter 전송 · ⇧Enter 줄바꿈")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        sendButton.bezelStyle = .rounded
        sendButton.target = self; sendButton.action = #selector(send)
        let footer = NSStackView(views: [hint, NSView(), sendButton])
        footer.spacing = 8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.required, for: .vertical)

        [header, modelRow, transcriptScroll, contextLabel, inputScroll, footer, status].forEach {
            view.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false
            $0.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16).isActive = true
            $0.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.heightAnchor.constraint(equalToConstant: 28),
            modelRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            modelRow.heightAnchor.constraint(equalToConstant: 26),
            transcriptScroll.topAnchor.constraint(equalTo: modelRow.bottomAnchor, constant: 10),
            transcriptScroll.bottomAnchor.constraint(equalTo: contextLabel.topAnchor, constant: -10),
            contextLabel.bottomAnchor.constraint(equalTo: inputScroll.topAnchor, constant: -6),
            inputScroll.heightAnchor.constraint(equalToConstant: 92),
            inputScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 28),
            footer.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
        refresh()
    }

    func show() {
        _ = view
        Task { [weak self] in
            guard let self else { return }
            do { try await self.session.connect() } catch { self.showError(error) }
        }
        view.window?.makeFirstResponder(composer)
    }

    func updateContext(page: Int, total: Int, hasSelection: Bool, available: Bool) {
        _ = view
        documentAvailable = available
        contextLabel.stringValue = "현재 \(page) / \(total)쪽" + (hasSelection ? " · 선택한 문장 포함" : " · 전체 PDF에서 답변")
        refreshControls()
    }

    func shutdown() {
        renderTask?.cancel()
        session.shutdown()
    }

    @objc private func closePanel() { onClose?() }

    @objc private func connect() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.connect()
                if !self.session.signedIn {
                    let url = try await self.session.loginURL()
                    guard NSWorkspace.shared.open(url) else { throw ChatError("브라우저에서 로그인 화면을 열지 못했습니다.") }
                }
            } catch { self.showError(error) }
        }
    }

    @objc private func modelChanged() {
        if let id = modelPicker.selectedItem?.representedObject as? String { session.selectModel(id) }
    }

    @objc private func newConversation() {
        do { try session.newConversation() } catch { showError(error) }
    }

    @objc private func send() {
        if session.isBusy { Task { await session.stop() }; return }
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard documentAvailable, !text.isEmpty, !session.isConnecting else { return }
        do {
            guard let context = try makeContext?() else { return }
            composer.string = ""
            Task { [weak self] in
                guard let self else { return }
                await self.session.send(text, context: context)
                // Restore the draft when failure happened before it entered the conversation.
                if !self.session.history.messages.contains(where: { $0.role == "user" && $0.text == text }), self.composer.string.isEmpty {
                    self.composer.string = text
                    self.refreshControls()
                }
            }
        } catch { showError(error) }
    }

    func textDidChange(_ notification: Notification) { refreshControls() }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, let target = ChatLink(url: url) {
            switch target {
            case .page(let page): onPage?(page)
            case .web(let url): NSWorkspace.shared.open(url)
            }
        }
        // Consume rejected links too; NSTextView must not open them itself.
        return true
    }

    private func refresh() {
        guard isViewLoaded else { return }
        status.stringValue = session.status
        status.toolTip = session.status
        let ids = modelPicker.itemArray.compactMap { $0.representedObject as? String }
        if ids != session.models.map(\.id) {
            modelPicker.removeAllItems()
            for model in session.models {
                modelPicker.addItem(withTitle: model.name)
                modelPicker.lastItem?.representedObject = model.id
            }
        }
        if let index = session.models.firstIndex(where: { $0.id == session.history.model }) { modelPicker.selectItem(at: index) }
        refreshControls()
        // Coalesce token deltas so large conversations do not relayout on every token.
        if renderTask == nil {
            renderTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let self else { return }
                self.renderTask = nil
                self.renderTranscript()
            }
        }
    }

    private func refreshControls() {
        sendButton.title = session.isBusy ? "중지" : "보내기"
        sendButton.isEnabled = session.isBusy || (documentAvailable && !session.isConnecting && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        modelPicker.isEnabled = !session.isBusy && !session.isConnecting && !session.models.isEmpty
        newButton.isEnabled = !session.isBusy
        connectButton.isHidden = session.signedIn && session.isConnected
        connectButton.title = session.isConnected ? "로그인" : "연결"
        connectButton.isEnabled = !session.isConnecting && !session.isBusy
    }

    private func renderTranscript() {
        let messages = session.history.messages
        let signature = messages.map { $0.id + $0.text }
        guard signature != renderedMessages || renderedBusy != session.isBusy || transcript.string.isEmpty else { return }
        renderedMessages = signature; renderedBusy = session.isBusy
        let oldHeight = transcript.bounds.height
        let visible = transcriptScroll.contentView.bounds
        let nearBottom = visible.maxY >= oldHeight - 70
        let content = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        let bodyAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        if messages.isEmpty {
            content.append(NSAttributedString(string: "PDF를 읽으며 바로 질문하세요\n\n전체 내용을 요약하거나, 현재 페이지의 수식·그림을 설명해 달라고 할 수 있습니다.\n\n문장을 선택하고 질문하면 선택한 내용도 함께 전달합니다. 질문에 필요한 PDF 내용은 ChatGPT로 전송됩니다.", attributes: bodyAttributes))
        }
        for message in messages {
            let label = message.role == "user" ? "나" : message.role == "assistant" ? "ChatGPT" : "안내"
            content.append(NSAttributedString(string: label + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: message.role == "user" ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]))
            if message.role == "assistant", let markdown = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in markdown.runs {
                    var attributes = bodyAttributes
                    if let intent = run.inlinePresentationIntent {
                        var font = NSFont.systemFont(ofSize: 13)
                        if intent.contains(.stronglyEmphasized) { font = .boldSystemFont(ofSize: 13) }
                        if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                        if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
                        attributes[.font] = font
                    }
                    if let link = run.link, ChatLink(url: link) != nil {
                        attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor
                    }
                    content.append(NSAttributedString(string: String(markdown.characters[run.range]), attributes: attributes))
                }
            } else {
                content.append(NSAttributedString(string: message.text, attributes: bodyAttributes))
            }
            content.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
        }
        transcript.textStorage?.setAttributedString(content)
        if nearBottom || !session.isBusy { transcript.scrollToEndOfDocument(nil) }
    }

    private func showError(_ error: Error) {
        status.stringValue = error.localizedDescription
        status.toolTip = error.localizedDescription
    }
}
