import AppKit
import PDFReaderCore

private final class ChatComposer: NSTextView {
    var onSend: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("PDF에 관해 질문하세요" as NSString).draw(at: NSPoint(x: textContainerOrigin.x + 5, y: textContainerOrigin.y),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
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
    private let transcript = ChatTranscriptView(frame: .zero)
    private let transcriptScroll = NSScrollView()
    private let composer = ChatComposer()
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let connectButton = NSButton(title: "연결", target: nil, action: nil)
    private let newButton = NSButton()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let zoomResetButton = NSButton(title: "100%", target: nil, action: nil)
    private let zoomLevels = [75, 90, 100, 110, 125, 150, 175, 200]
    private var zoomPercent = 100
    private let status = NSTextField(wrappingLabelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
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
        view = ChatPanelBackground()
        let title = NSTextField(labelWithString: "ChatGPT")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        newButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "새 대화")
        newButton.bezelStyle = .texturedRounded
        newButton.target = self; newButton.action = #selector(newConversation)
        newButton.toolTip = "새 대화 시작 · 기존 대화는 파일로 보관합니다"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "대화창 닫기")!, target: self, action: #selector(closePanel))
        close.bezelStyle = .texturedRounded
        zoomOutButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "대화 축소")
        zoomInButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "대화 확대")
        zoomOutButton.action = #selector(zoomOut)
        zoomInButton.action = #selector(zoomIn)
        zoomResetButton.action = #selector(resetZoom)
        zoomResetButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomResetButton.toolTip = "대화 배율 · 클릭하면 100%로 복원"
        for button in [zoomOutButton, zoomResetButton, zoomInButton] {
            button.target = self
            button.bezelStyle = .texturedRounded
        }
        zoomOutButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        zoomInButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        zoomResetButton.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let zoomControls = NSStackView(views: [zoomOutButton, zoomResetButton, zoomInButton])
        zoomControls.spacing = 2
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, zoomControls, newButton, close])
        header.spacing = 6
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

        transcript.textDelegate = self
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.contentView.drawsBackground = false

        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        composer.isRichText = false
        composer.drawsBackground = false
        composer.font = .systemFont(ofSize: 13)
        composer.textContainerInset = NSSize(width: 2, height: 4)
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
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.contentView.drawsBackground = false
        let inputSurface = ChatRoundedSurface()
        inputSurface.addSubview(inputScroll)
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(labelWithString: "Enter 전송 · ⇧Enter 줄바꿈")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        sendButton.bezelStyle = .circular
        sendButton.imagePosition = .imageOnly
        sendButton.imageScaling = .scaleProportionallyDown
        sendButton.target = self; sendButton.action = #selector(send)
        inputSurface.addSubview(hint)
        inputSurface.addSubview(sendButton)
        hint.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setContentCompressionResistancePriority(.required, for: .vertical)

        [header, modelRow, transcriptScroll, contextLabel, inputSurface, status].forEach {
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
            transcriptScroll.bottomAnchor.constraint(equalTo: contextLabel.topAnchor, constant: -12),
            contextLabel.bottomAnchor.constraint(equalTo: inputSurface.topAnchor, constant: -8),
            inputSurface.heightAnchor.constraint(equalToConstant: 120),
            inputSurface.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            inputScroll.topAnchor.constraint(equalTo: inputSurface.topAnchor, constant: 10),
            inputScroll.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 10),
            inputScroll.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -10),
            inputScroll.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -6),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
            sendButton.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: inputSurface.bottomAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 14),
            hint.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
        let savedZoom = UserDefaults.standard.integer(forKey: "chatZoomPercent")
        applyZoom(zoomLevels.contains(savedZoom) ? savedZoom : 100)
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        transcript.fitViewport()
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

    @objc private func zoomOut() {
        if let value = zoomLevels.last(where: { $0 < zoomPercent }) { applyZoom(value) }
    }

    @objc private func zoomIn() {
        if let value = zoomLevels.first(where: { $0 > zoomPercent }) { applyZoom(value) }
    }

    @objc private func resetZoom() { applyZoom(100) }

    private func applyZoom(_ percent: Int) {
        zoomPercent = percent
        UserDefaults.standard.set(percent, forKey: "chatZoomPercent")
        zoomResetButton.title = "\(percent)%"
        zoomResetButton.setAccessibilityLabel("대화 배율 \(percent)% · 기본 배율로 복원")
        zoomOutButton.isEnabled = percent > zoomLevels[0]
        zoomInButton.isEnabled = percent < zoomLevels[zoomLevels.count - 1]
        let scale = CGFloat(percent) / 100
        transcript.setTextScale(scale)
        composer.font = .systemFont(ofSize: 13 * scale)
        composer.needsDisplay = true
    }

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
            composer.needsDisplay = true
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
                self.transcript.update(messages: self.session.history.messages, isBusy: self.session.isBusy)
            }
        }
    }

    private func refreshControls() {
        let action = session.isBusy ? "답변 중지" : "질문 보내기"
        sendButton.image = NSImage(systemSymbolName: session.isBusy ? "stop.fill" : "arrow.up", accessibilityDescription: action)
        sendButton.toolTip = action
        sendButton.setAccessibilityLabel(action)
        sendButton.isEnabled = session.isBusy || (documentAvailable && !session.isConnecting && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        modelPicker.isEnabled = !session.isBusy && !session.isConnecting && !session.models.isEmpty
        newButton.isEnabled = !session.isBusy
        connectButton.isHidden = session.signedIn && session.isConnected
        connectButton.title = session.isConnected ? "로그인" : "연결"
        connectButton.isEnabled = !session.isConnecting && !session.isBusy
    }

    private func showError(_ error: Error) {
        status.stringValue = error.localizedDescription
        status.toolTip = error.localizedDescription
    }
}
