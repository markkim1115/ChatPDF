import AppKit
import PDFKit

public final class ReaderPDFView: PDFView {
    private var dragMonitor: Any?
    private struct TextDrag {
        let page: PDFPage
        let point: CGPoint
        let layout: PDFSelectionRepair.Layout?
        let highlight: Highlight?
        var moved = false
    }
    private var textDrag: TextDrag?
    private var selectionObserver: NSObjectProtocol?
    private var selectedHighlight: Highlight?
    private final class SelectionOverlay: NSView {
        weak var reader: ReaderPDFView?
        override var isFlipped: Bool { reader?.isFlipped ?? false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { reader?.drawRepairedSelection() }
    }
    private var selectionOverlay: SelectionOverlay?
    private var scrollObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    private var repairedSelectionBounds: [ObjectIdentifier: [CGRect]] = [:]

    public var highlightsToRemove: [Highlight] {
        if let hit = selectedHighlight, hit.page.document === document,
           hit.page.annotations.contains(where: { $0 === hit.annotation }) { return [hit] }
        return currentSelection.map(Highlights.intersecting) ?? []
    }
    public var correctLineBreaks = true
    public var didCopy: ((Bool) -> Void)?
    public var highlightSelection: (() -> Void)?
    public var removeHighlights: (() -> Void)?
    public var openFiles: (([URL]) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        backgroundColor = NSColor.underPageBackgroundColor
        autoScales = true
        minScaleFactor = 0.15
        maxScaleFactor = 8
        selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: self, queue: .main) { [weak self] _ in
            self?.selectedHighlight = nil
            self?.updateSelectionGeometry()
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateSelectionGeometry() {
        repairedSelectionBounds.removeAll()
        selectionOverlay?.needsDisplay = true
        guard let selection = currentSelection else { return }
        var geometry = PDFTextMetrics.LineGeometry()
        var bounds: [ObjectIdentifier: [CGRect]] = [:]
        var repaired = false
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let box = geometry.bounds(of: line, on: page)
                repaired = repaired || box != line.bounds(for: page)
                bounds[ObjectIdentifier(page), default: []].append(box)
            }
        }
        if repaired { repairedSelectionBounds = bounds }
        selectionOverlay?.needsDisplay = true
    }

    public override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        // PDFKit's native selection layer uses malformed glyph bounds even when
        // its page drawing hooks are overridden. Hide only that layer and draw
        // the recovered rectangles above it; the actual text selection is kept.
        var geometry = PDFTextMetrics.LineGeometry()
        if let selection, selection.selectionsByLine().contains(where: { line in
            line.pages.contains { geometry.bounds(of: line, on: $0) != line.bounds(for: $0) }
        }) { selection.color = .clear }
        super.setCurrentSelection(selection, animate: animate)
    }

    private func drawRepairedSelection() {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        for page in visiblePages {
            for box in repairedSelectionBounds[ObjectIdentifier(page)] ?? [] {
                convert(box, from: page).fill()
            }
        }
    }

    deinit {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        textDrag = nil
        selectedHighlight = nil
        guard window != nil else { return }
        if selectionOverlay == nil {
            let overlay = SelectionOverlay(frame: bounds)
            overlay.reader = self
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            selectionOverlay = overlay
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? NSClipView)?.documentView === self.documentView else { return }
                self.selectionOverlay?.needsDisplay = true
            }
            scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) { [weak self] _ in
                self?.selectionOverlay?.needsDisplay = true
            }
        }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleSelectionEvent(event)
        }
    }

    // Own ordinary text drags before PDFKit enters its private tracking loop.
    // Returning nil consumes the event; modified and multi-click gestures remain native.
    func handleSelectionEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.type == .keyDown {
            let responder = window?.firstResponder as? NSView
            guard responder === self || (responder?.isDescendant(of: documentView ?? self) == true) else { return event }
            if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               document?.allowsCommenting == true, !highlightsToRemove.isEmpty {
                removeHighlights?()
                return nil
            }
            if event.keyCode == 53, selectedHighlight != nil { clearSelection(); selectedHighlight = nil; return nil }
            return event
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            textDrag = nil
            guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
                  let content = documentView,
                  let hit = hitTest(convert(point, to: superview)), hit.isDescendant(of: content),
                  let page = page(for: point, nearest: false) else { return event }
            selectedHighlight = nil
            let pagePoint = convert(point, to: page)
            if let annotation = page.annotation(at: pagePoint), annotation.type != "Highlight" { return event }
            let highlight = Highlights.at(pagePoint, on: page)
            let layout = PDFSelectionRepair.Layout(page: page)
            guard layout?.contains(pagePoint) == true || highlight != nil else { return event }
            textDrag = TextDrag(page: page, point: pagePoint, layout: layout, highlight: highlight)
            window?.makeFirstResponder(self)
            clearSelection()
            return nil
        case .leftMouseDragged, .leftMouseUp:
            guard var drag = textDrag, document === drag.page.document else { textDrag = nil; return event }
            let start = convert(drag.point, from: drag.page)
            drag.moved = drag.moved || hypot(point.x - start.x, point.y - start.y) > 3
            if drag.moved, let page = page(for: point, nearest: true), let document {
                let end = convert(point, to: page)
                let selection = page === drag.page ? drag.layout?.selection(from: drag.point, to: end) : nil
                setCurrentSelection(selection ?? document.selection(from: drag.page, at: drag.point, to: page, at: end), animate: false)
                if event.type == .leftMouseDragged { _ = documentView?.autoscroll(with: event) }
            }
            if event.type == .leftMouseUp {
                if !drag.moved, let highlight = drag.highlight { select(highlight) }
                textDrag = nil
            } else { textDrag = drag }
            return nil
        default: return event
        }
    }

    private func select(_ highlight: Highlight) {
        guard let document = highlight.page.document else { return }
        let selection = PDFSelection(document: document)
        for rect in Highlights.regions(of: highlight.annotation) {
            if let part = highlight.page.selection(for: rect) { selection.add(part) }
        }
        setCurrentSelection(selection, animate: false)
        selectedHighlight = highlight
    }

    public override func copy(_ sender: Any?) {
        copySelection(corrected: correctLineBreaks)
    }

    @objc public func copyOriginal(_ sender: Any?) { copySelection(corrected: false) }
    @objc public func copyCleaned(_ sender: Any?) { copySelection(corrected: true) }

    @discardableResult
    public func copySelection(corrected: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let document, document.allowsCopying, let selection = currentSelection,
              let original = selection.string, !original.isEmpty else { return false }
        let text = corrected ? PDFTextExtractor.clean(selection) : original
        guard !text.isEmpty else { return false }
        // Publish only plain text, so rich-text destinations cannot choose an RTF
        // flavor that still contains the PDF's physical line breaks.
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if success { didCopy?(corrected) }
        return success
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == .command {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false), let highlight = Highlights.at(convert(point, to: page), on: page) {
            select(highlight)
        }
        let menu = NSMenu()
        // Route both copy and deletion through the same handlers as the toolbar.
        if currentSelection?.string?.isEmpty == false {
            let copy = NSMenuItem(title: correctLineBreaks ? "줄바꿈 보정하여 복사" : "복사",
                                  action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.insertItem(copy, at: 0)
            let original = NSMenuItem(title: "원문 그대로 복사", action: #selector(copyOriginal(_:)), keyEquivalent: "")
            original.target = self
            menu.insertItem(original, at: 1)
            let highlight = NSMenuItem(title: "형광펜 표시", action: #selector(markSelection(_:)), keyEquivalent: "")
            highlight.target = self
            menu.insertItem(highlight, at: 2)
        }
        if document?.allowsCommenting == true, !highlightsToRemove.isEmpty {
            let remove = NSMenuItem(title: "형광펜 지우기", action: #selector(eraseHighlights(_:)), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        return menu.items.isEmpty ? super.menu(for: event) : menu
    }

    @objc private func markSelection(_ sender: Any?) { highlightSelection?() }
    @objc private func eraseHighlights(_ sender: Any?) { removeHighlights?() }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pdfURLs(sender).isEmpty ? [] : .copy
    }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !pdfURLs(sender).isEmpty }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = pdfURLs(sender)
        guard !urls.isEmpty, let openFiles else { return false }
        openFiles(urls)
        return true
    }
    private func pdfURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
    }
}
