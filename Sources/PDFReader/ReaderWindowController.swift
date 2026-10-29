import AppKit
import PDFKit
import PDFReaderCore

final class ReaderWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, PDFDocumentDelegate, NSMenuItemValidation {
    let pdfView = ReaderPDFView(frame: .zero)
    private unowned let readerDocument: ReaderDocument
    private let splitView = NSSplitView()
    private let contentSplit = ChatSplitView()
    private var chatController: PDFChatViewController?
    private var chatPaneWidth: CGFloat = 400
    private let sidebar = NSView()
    private let thumbnails = PDFThumbnailView()
    private let searchBar = NSView()
    private let searchField = NSSearchField()
    private let searchCount = NSTextField(labelWithString: "")
    private let pageField = NSTextField(string: "1")
    private let pageTotal = NSTextField(labelWithString: "/ 1")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusOverlay = NSVisualEffectView()
    private let copySwitch = NSButton(checkboxWithTitle: "줄바꿈 보정", target: nil, action: nil)
    private var searchHeight: NSLayoutConstraint!
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var searchWork: DispatchWorkItem?
    private var statusWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var highlightColor = NSColor.systemYellow
    private var highlightButton: NSButton!
    private var ocrRegion: OCRRegionView?
    private var ocrRequest: UUID?
    private var ocrButton: NSButton!
    private var chatGPTButton: NSButton!
    private let palette: [(String, NSColor)] = [("노랑", .systemYellow), ("초록", .systemGreen), ("파랑", .systemCyan), ("분홍", .systemPink)]

    init(readerDocument: ReaderDocument) {
        self.readerDocument = readerDocument
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 780, height: 520)
        window.title = readerDocument.displayName
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "PDFReader.document"
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("ReaderWindow")
        buildContent()
        buildToolbar()
        configurePDF()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.chatController?.shutdown() }
        })
        window.makeFirstResponder(pdfView)
        if readerDocument.pdf.isLocked {
            DispatchQueue.main.async { [weak self] in self?.askForPassword() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        searchWork?.cancel()
        statusWork?.cancel()
        pdfView.document?.cancelFindString()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let sidebarTitle = NSTextField(labelWithString: "페이지")
        sidebarTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        sidebar.addSubview(material)
        pin(material, to: sidebar)
        sidebar.addSubview(sidebarTitle)
        sidebar.addSubview(thumbnails)
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.thumbnailSize = NSSize(width: 118, height: 158)
        thumbnails.backgroundColor = .clear
        NSLayoutConstraint.activate([
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            thumbnails.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 12),
            thumbnails.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            thumbnails.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            thumbnails.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(pdfView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 155).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 270).isActive = true
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .paneSplitter
        contentSplit.addArrangedSubview(splitView)
        contentSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        searchField.placeholderString = "문서에서 검색"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(nextMatch(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        searchCount.textColor = .secondaryLabelColor
        let previous = iconButton("chevron.up", label: "이전 검색 결과", action: #selector(previousMatch(_:)))
        let next = iconButton("chevron.down", label: "다음 검색 결과", action: #selector(nextMatch(_:)))
        let close = iconButton("xmark", label: "검색 닫기", action: #selector(closeSearch(_:)))
        let searchStack = NSStackView(views: [searchField, searchCount, previous, next, close])
        searchStack.spacing = 10
        searchBar.addSubview(searchStack)
        searchStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchStack.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchStack.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 18),
            searchStack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -18),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        searchBar.isHidden = true

        [searchBar, contentSplit].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        searchHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: content.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), searchHeight,
            contentSplit.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            contentSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        // Feedback floats over the document only while needed; no bottom bar
        // reserves space from the PDF or the thumbnail sidebar.
        statusOverlay.material = .popover
        statusOverlay.blendingMode = .withinWindow
        statusOverlay.wantsLayer = true
        statusOverlay.layer?.cornerRadius = 8
        statusOverlay.layer?.masksToBounds = true
        statusOverlay.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusOverlay)
        statusOverlay.addSubview(statusLabel)
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusOverlay.topAnchor.constraint(equalTo: pdfView.topAnchor, constant: 12),
            statusOverlay.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            statusOverlay.widthAnchor.constraint(lessThanOrEqualTo: pdfView.widthAnchor, constant: -32),
            statusLabel.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: statusOverlay.topAnchor, constant: 7),
            statusLabel.bottomAnchor.constraint(equalTo: statusOverlay.bottomAnchor, constant: -7)
        ])
        content.layoutSubtreeIfNeeded()
        splitView.setPosition(180, ofDividerAt: 0)
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("sidebar"), NSToolbarItem.Identifier("navigation"), .flexibleSpace,
         NSToolbarItem.Identifier("zoom"), NSToolbarItem.Identifier("highlight"),
         NSToolbarItem.Identifier("copy"), NSToolbarItem.Identifier("chatGPT"), NSToolbarItem.Identifier("search")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "sidebar":
            item.label = "사이드바"
            item.view = iconButton("sidebar.left", label: "사이드바 보기 / 가리기", action: #selector(toggleSidebar(_:)))
        case "navigation":
            pageField.alignment = .center
            pageField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            pageField.bezelStyle = .roundedBezel
            pageField.target = self
            pageField.action = #selector(goToPage(_:))
            pageField.setAccessibilityLabel("현재 페이지")
            pageField.widthAnchor.constraint(equalToConstant: 44).isActive = true
            pageTotal.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            pageTotal.textColor = .secondaryLabelColor
            item.label = "페이지 이동"
            item.view = stack([iconButton("chevron.left", label: "이전 페이지", action: #selector(previousPage(_:))), pageField,
                               pageTotal, iconButton("chevron.right", label: "다음 페이지", action: #selector(nextPage(_:)))])
        case "zoom":
            item.label = "확대 / 축소"
            zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            zoomLabel.textColor = .secondaryLabelColor
            zoomLabel.alignment = .center
            zoomLabel.setAccessibilityLabel("확대 비율")
            zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            item.view = stack([iconButton("minus.magnifyingglass", label: "축소 · ⌘−", action: #selector(zoomOut(_:))), zoomLabel,
                               iconButton("plus.magnifyingglass", label: "확대 · ⌘+", action: #selector(zoomIn(_:))),
                               iconButton("arrow.up.left.and.arrow.down.right", label: "페이지 맞춤 · ⌘0", action: #selector(fitPage(_:)))])
        case "highlight":
            item.label = "형광펜"
            highlightButton = iconButton("highlighter", label: "선택한 텍스트에 형광펜 · ⇧⌘H", action: #selector(highlight(_:)))
            highlightButton.contentTintColor = .systemOrange
            let colors = NSPopUpButton(frame: .zero, pullsDown: true)
            colors.bezelStyle = .texturedRounded
            colors.imagePosition = .imageOnly
            colors.addItem(withTitle: "")
            colors.widthAnchor.constraint(equalToConstant: 26).isActive = true
            for (index, entry) in palette.enumerated() {
                let menuItem = NSMenuItem(title: entry.0, action: #selector(selectColor(_:)), keyEquivalent: "")
                menuItem.tag = index
                menuItem.target = self
                menuItem.image = colorDot(entry.1)
                menuItem.state = index == 0 ? .on : .off
                colors.menu?.addItem(menuItem)
            }
            colors.menu?.addItem(.separator())
            let erase = NSMenuItem(title: "형광펜 지우기", action: #selector(eraseHighlights(_:)), keyEquivalent: "")
            erase.target = self
            colors.menu?.addItem(erase)
            colors.setAccessibilityLabel("형광펜 색상 및 지우기")
            item.view = stack([highlightButton, colors])
        case "copy":
            item.label = "줄바꿈 보정"
            copySwitch.target = self
            copySwitch.action = #selector(toggleCleanCopy(_:))
            copySwitch.font = .systemFont(ofSize: 12, weight: .medium)
            copySwitch.toolTip = "⌘C로 복사할 때 지면의 줄바꿈을 없애고 문단을 유지합니다."
            ocrButton = iconButton("text.viewfinder", label: "영역 텍스트 인식 · ⇧⌘O", action: #selector(recognizeRegion(_:)))
            item.view = stack([copySwitch, ocrButton])
        case "chatGPT":
            item.label = "ChatGPT 대화창"
            chatGPTButton = iconButton("bubble.left.and.bubble.right", label: "ChatGPT 대화창 · ⌥⌘G", action: #selector(toggleChat(_:)))
            chatGPTButton.title = "ChatGPT"
            chatGPTButton.imagePosition = .imageLeading
            item.view = chatGPTButton
        case "search":
            item.label = "검색"
            item.view = iconButton("magnifyingglass", label: "문서 검색 · ⌘F", action: #selector(showSearch(_:)))
        default: return nil
        }
        return item
    }

    private func configurePDF() {
        pdfView.document = readerDocument.pdf
        thumbnails.pdfView = pdfView
        readerDocument.pdf.delegate = self
        pdfView.correctLineBreaks = UserDefaults.standard.object(forKey: "correctLineBreaks") as? Bool ?? true
        copySwitch.state = pdfView.correctLineBreaks ? .on : .off
        pdfView.didCopy = { [weak self] cleaned in self?.showStatus(cleaned ? "복사 완료 · 지면 줄바꿈을 정리했습니다" : "복사 완료 · 원문의 줄바꿈을 유지했습니다") }
        pdfView.highlightSelection = { [weak self] in self?.highlight(nil) }
        pdfView.removeHighlights = { [weak self] in self?.eraseHighlights(nil) }
        pdfView.openFiles = { urls in urls.forEach { AppDelegate.open($0) } }
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewSelectionChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in self?.refreshControls() })
        }
        refreshControls()
    }

    func reloadDocument() {
        cancelOCR()
        closeSearch(nil)
        matches = []
        matchIndex = -1
        searchField.stringValue = ""
        pdfView.document = readerDocument.pdf
        readerDocument.pdf.delegate = self
        pdfView.autoScales = true
        refreshControls()
    }

    private func refreshControls() {
        let page = pdfView.currentPage.map { readerDocument.pdf.index(for: $0) + 1 } ?? 1
        if window?.firstResponder !== pageField.currentEditor() { pageField.stringValue = "\(page)" }
        pageTotal.stringValue = "/ \(readerDocument.pdf.pageCount)"
        zoomLabel.stringValue = "\(Int(pdfView.scaleFactor * 100))%"
        highlightButton?.isEnabled = pdfView.currentSelection?.string?.isEmpty == false && readerDocument.pdf.allowsCommenting
        ocrButton?.isEnabled = readerDocument.pdf.allowsCopying && !readerDocument.pdf.isLocked && ocrRequest == nil
        chatGPTButton?.isEnabled = canSendToChatGPT
        chatController?.updateContext(page: page, total: readerDocument.pdf.pageCount,
                                      hasSelection: pdfView.currentSelection?.string?.isEmpty == false, available: canSendToChatGPT)
    }

    @objc func toggleChat(_ sender: Any?) {
        if let controller = chatController, controller.view.superview != nil {
            chatPaneWidth = controller.view.frame.width
            contentSplit.removeArrangedSubview(controller.view)
            controller.view.removeFromSuperview()
            contentSplit.adjustSubviews()
            window?.makeFirstResponder(pdfView)
            return
        }
        guard canSendToChatGPT else { return }
        if chatController == nil {
            let controller = PDFChatViewController(documentURL: readerDocument.fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
            controller.onClose = { [weak self] in self?.toggleChat(nil) }
            controller.onPage = { [weak self] number in
                guard let self, number > 0, let page = self.readerDocument.pdf.page(at: number - 1) else { return }
                self.pdfView.go(to: page)
            }
            controller.makeContext = { [weak self] in
                guard let self else { throw ChatError("문서가 닫혔습니다.") }
                let page = self.pdfView.currentPage.map { self.readerDocument.pdf.index(for: $0) + 1 } ?? 1
                let selection = self.pdfView.currentSelection.map { PDFTextExtractor.clean($0) } ?? ""
                return try PDFChatContext(document: self.readerDocument.pdf, title: self.readerDocument.displayName ?? "PDF",
                                          currentPage: page, selection: selection)
            }
            controller.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            chatController = controller
        }
        guard let controller = chatController else { return }
        contentSplit.addArrangedSubview(controller.view)
        // Preserve chat width when the window resizes, while staying below
        // AppKit's divider-drag priority (490) so the user can resize it.
        contentSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        window?.contentView?.layoutSubtreeIfNeeded()
        contentSplit.setPosition(max(300, contentSplit.bounds.width - contentSplit.dividerThickness - chatPaneWidth), ofDividerAt: 0)
        refreshControls()
        controller.show()
    }

    func shutdownChat() { chatController?.shutdown() }

    private var canSendToChatGPT: Bool {
        !readerDocument.pdf.isLocked && readerDocument.pdf.allowsCopying && readerDocument.pdf.pageCount > 0
    }

    @objc func sendToChatGPT(_ sender: Any?) {
        guard canSendToChatGPT else { return }
        guard NSWorkspace.shared.urlForApplication(toOpen: URL(string: "codex://new")!) != nil else {
            showChatGPTError("ChatGPT 데스크톱 앱을 설치한 뒤 다시 시도해 주세요.")
            return
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("PDF Reader/ChatGPT", isDirectory: true)
            // Keep the exact document state available when the chat is resumed later.
            // This also includes annotations that have not been saved to the original.
            let pdfURL = try PrivateChatStorage.exportPDF(readerDocument.data(ofType: "com.adobe.pdf"),
                                                         directory: directory)
            let page = pdfView.currentPage.map { readerDocument.pdf.index(for: $0) + 1 } ?? 1
            let url = ChatGPTLink.make(pdfURL: pdfURL, documentName: readerDocument.displayName ?? "PDF",
                                       page: page, pageCount: readerDocument.pdf.pageCount)
            guard NSWorkspace.shared.open(url) else {
                showChatGPTError("ChatGPT를 열지 못했습니다. 앱을 실행한 뒤 다시 시도해 주세요.")
                return
            }
            showStatus("ChatGPT에서 전송을 누르면 PDF를 읽기 시작합니다")
        } catch {
            showChatGPTError("PDF를 준비하지 못했습니다. \(error.localizedDescription)")
        }
    }

    private func showChatGPTError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "ChatGPT로 보내기"
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.beginSheetModal(for: window)
    }

    @objc func copy(_ sender: Any?) { pdfView.copy(sender) }
    @objc func copyOriginal(_ sender: Any?) { pdfView.copyOriginal(sender) }
    @objc func copyCleaned(_ sender: Any?) { pdfView.copyCleaned(sender) }

    @objc func recognizeRegion(_ sender: Any?) {
        guard readerDocument.pdf.allowsCopying, !readerDocument.pdf.isLocked, ocrRequest == nil else { return }
        if ocrRegion != nil { cancelOCR(); return }
        let overlay = OCRRegionView(frame: pdfView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.didCancel = { [weak self] in self?.cancelOCR() }
        overlay.didSelect = { [weak self] rect in self?.recognize(rect) }
        ocrRegion = overlay
        pdfView.addSubview(overlay)
        window?.makeFirstResponder(overlay)
        showStatus("인식할 문단을 드래그하세요 · 한 페이지의 영역 선택 · Esc로 취소", persistent: true)
    }

    private func cancelOCR() {
        ocrRequest = nil
        ocrRegion?.removeFromSuperview()
        ocrRegion = nil
        window?.makeFirstResponder(pdfView)
        refreshControls()
        showStatus("텍스트 인식을 취소했습니다")
    }

    private func recognize(_ rect: CGRect) {
        guard let page = pdfView.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: false) else {
            showStatus("페이지 안의 문단을 선택해 주세요"); return
        }
        let pageFrame = pdfView.convert(page.bounds(for: .cropBox), from: page)
        guard pageFrame.insetBy(dx: -1, dy: -1).contains(rect) else {
            showStatus("한 페이지 안에서 영역을 선택해 주세요"); return
        }
        let region = pdfView.convert(rect, to: page).applying(page.transform(for: .cropBox))
        ocrRegion?.removeFromSuperview()
        ocrRegion = nil
        window?.makeFirstResponder(pdfView)
        do {
            let image = try PDFOCR.render(page: page, region: region)
            let requestID = UUID()
            ocrRequest = requestID
            refreshControls()
            showStatus("선택 영역의 문자를 인식하는 중…", persistent: true)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try PDFOCR.recognize(image) }
                DispatchQueue.main.async {
                    guard let self, self.ocrRequest == requestID, self.window?.isVisible == true else { return }
                    self.ocrRequest = nil
                    self.refreshControls()
                    switch result {
                    case .success(let lines):
                        let text = PDFTextExtractor.cleanRecognized(lines, in: region, on: page)
                        self.showOCRResult(text)
                    case .failure(let error): self.showStatus(error.localizedDescription)
                    }
                }
            }
        } catch { showStatus(error.localizedDescription) }
    }

    private func showOCRResult(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "인식한 텍스트"
        alert.informativeText = "문자 인식 결과를 원문과 확인하고 수정할 수 있습니다. 줄바꿈은 정리되어 있습니다."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.addButton(withTitle: "복사")
        alert.addButton(withTitle: "닫기")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { self?.showStatus("텍스트 인식 결과를 닫았습니다"); return }
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(editor.string, forType: .string) {
                self?.showStatus("인식한 텍스트를 복사했습니다")
            }
        }
        showStatus("문자 인식 완료 · 결과를 확인한 뒤 복사하세요")
    }
    @objc func highlight(_ sender: Any?) {
        guard let selection = pdfView.currentSelection, !selection.string.isNilOrEmpty else { NSSound.beep(); return }
        guard readerDocument.pdf.allowsCommenting else { showStatus("이 PDF는 주석 추가를 허용하지 않습니다"); return }
        readerDocument.highlight(selection, color: highlightColor)
        pdfView.clearSelection()
        showStatus("형광펜을 표시했습니다 · ⌘S로 저장 · ⌘Z로 취소")
    }
    @objc func eraseHighlights(_ sender: Any?) {
        guard readerDocument.pdf.allowsCommenting else { showStatus("이 PDF는 주석 변경을 허용하지 않습니다"); return }
        let highlights = pdfView.highlightsToRemove
        guard !highlights.isEmpty else { showStatus("지울 형광펜을 클릭하거나 해당 텍스트를 선택하세요"); return }
        readerDocument.erase(highlights)
        pdfView.clearSelection()
        showStatus("선택 영역의 형광펜을 지웠습니다 · ⌘Z로 취소")
    }
    @objc private func selectColor(_ sender: NSMenuItem) {
        highlightColor = palette[sender.tag].1
        highlightButton.contentTintColor = highlightColor == .systemYellow ? .systemOrange : highlightColor
        sender.menu?.items.filter { $0.action == #selector(selectColor(_:)) }.forEach { $0.state = $0 === sender ? .on : .off }
    }
    @objc func toggleCleanCopy(_ sender: Any?) {
        pdfView.correctLineBreaks.toggle()
        copySwitch.state = pdfView.correctLineBreaks ? .on : .off
        UserDefaults.standard.set(pdfView.correctLineBreaks, forKey: "correctLineBreaks")
        showStatus(pdfView.correctLineBreaks ? "줄바꿈 보정 켜짐 · ⌘C로 바로 복사하세요" : "원문 복사 모드 · 지면의 줄바꿈을 유지합니다")
    }
    @objc func toggleSidebar(_ sender: Any?) {
        sidebar.isHidden.toggle()
        splitView.adjustSubviews()
        if !sidebar.isHidden { splitView.setPosition(180, ofDividerAt: 0) }
    }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func zoomIn(_ sender: Any?) { pdfView.autoScales = false; pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.autoScales = false; pdfView.zoomOut(sender) }
    @objc func fitPage(_ sender: Any?) { pdfView.autoScales = true }
    @objc func actualSize(_ sender: Any?) { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    @objc func goToPage(_ sender: Any?) {
        let index = pageField.integerValue - 1
        if index >= 0, index < readerDocument.pdf.pageCount, let page = readerDocument.pdf.page(at: index) { pdfView.go(to: page) }
        else { NSSound.beep() }
        window?.makeFirstResponder(pdfView)
        refreshControls()
    }
    @objc func showSearch(_ sender: Any?) {
        searchBar.isHidden = false
        searchHeight.constant = 46
        window?.makeFirstResponder(searchField)
    }
    @objc func closeSearch(_ sender: Any?) {
        searchWork?.cancel()
        readerDocument.pdf.cancelFindString()
        searchBar.isHidden = true
        searchHeight.constant = 0
        pdfView.highlightedSelections = nil
        window?.makeFirstResponder(pdfView)
    }
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        searchWork?.cancel()
        readerDocument.pdf.cancelFindString()
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
        searchCount.stringValue = ""
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchCount.stringValue = "검색 중…"
            self.readerDocument.pdf.beginFindString(query, withOptions: [.caseInsensitive])
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func didMatchString(_ instance: PDFSelection) {
        instance.color = NSColor.systemYellow.withAlphaComponent(0.35)
        matches.append(instance)
        if matchIndex == -1 { matchIndex = 0; revealMatch() }
        searchCount.stringValue = "\(matchIndex + 1) / \(matches.count)"
    }
    func documentDidEndDocumentFind(_ notification: Notification) {
        guard !searchBar.isHidden else { return }
        searchCount.stringValue = matches.isEmpty ? "검색 결과 없음" : "\(matchIndex + 1) / \(matches.count)"
    }
    @objc func nextMatch(_ sender: Any?) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matches.count
        revealMatch()
    }
    @objc func previousMatch(_ sender: Any?) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matches.count) % matches.count
        revealMatch()
    }
    private func revealMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let selection = matches[matchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        searchCount.stringValue = "\(matchIndex + 1) / \(matches.count)"
        // Only the active result is painted. Large documents never accumulate
        // thousands of overlay selections during a search.
        pdfView.highlightedSelections = [selection]
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSearch(nil); return true }
        return false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(copyOriginal(_:)), #selector(copyCleaned(_:)):
            return readerDocument.pdf.allowsCopying && pdfView.currentSelection?.string?.isEmpty == false
        case #selector(highlight(_:)):
            return readerDocument.pdf.allowsCommenting && pdfView.currentSelection?.string?.isEmpty == false
        case #selector(eraseHighlights(_:)):
            return readerDocument.pdf.allowsCommenting && !pdfView.highlightsToRemove.isEmpty
        case #selector(recognizeRegion(_:)):
            return readerDocument.pdf.allowsCopying && !readerDocument.pdf.isLocked && ocrRequest == nil
        case #selector(sendToChatGPT(_:)):
            return canSendToChatGPT
        case #selector(toggleChat(_:)):
            menuItem.state = chatController?.view.superview != nil ? .on : .off
            return canSendToChatGPT
        case #selector(toggleCleanCopy(_:)):
            menuItem.state = pdfView.correctLineBreaks ? .on : .off
        case #selector(toggleSidebar(_:)):
            menuItem.state = sidebar.isHidden ? .off : .on
        default: break
        }
        return true
    }

    private func showStatus(_ text: String, persistent: Bool = false) {
        statusWork?.cancel()
        statusLabel.stringValue = text
        statusOverlay.isHidden = false
        guard !persistent else { return }
        let work = DispatchWorkItem { [weak self] in self?.statusOverlay.isHidden = true }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func askForPassword() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "암호로 보호된 PDF"
        alert.informativeText = "문서를 열려면 암호를 입력해 주세요."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "암호"
        alert.accessoryView = field
        alert.addButton(withTitle: "열기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if self.readerDocument.pdf.unlock(withPassword: field.stringValue) {
                    self.pdfView.document = self.readerDocument.pdf
                    self.pdfView.autoScales = true
                    self.refreshControls()
                } else { self.askForPassword() }
            } else { self.close() }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }
    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                                     view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor)])
    }
    private func colorDot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
