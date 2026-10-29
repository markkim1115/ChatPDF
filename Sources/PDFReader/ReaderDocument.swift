import AppKit
import PDFKit
import PDFReaderCore

@objc(ReaderDocument)
final class ReaderDocument: NSDocument {
    var pdf = PDFDocument()

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let loaded = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF 파일을 열 수 없습니다. 파일이 손상되었거나 PDF 형식이 아닙니다."])
        }
        pdf.cancelFindString()
        pdf.delegate = nil
        pdf = loaded
        windowControllers.compactMap { $0 as? ReaderWindowController }.forEach { $0.reloadDocument() }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard !pdf.isLocked, let data = pdf.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "PDF를 저장할 수 없습니다. 문서의 잠금 상태와 저장 위치를 확인해 주세요."])
        }
        return data
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(readerDocument: self))
    }

    func highlight(_ selection: PDFSelection, color: NSColor) {
        guard pdf.allowsCommenting else { NSSound.beep(); return }
        apply(Highlights.make(for: selection, color: color), adding: true)
    }

    func erase(_ selection: PDFSelection) {
        erase(Highlights.intersecting(selection))
    }

    func erase(_ highlights: [Highlight]) {
        guard pdf.allowsCommenting else { NSSound.beep(); return }
        apply(highlights, adding: false)
    }

    private func apply(_ highlights: [Highlight], adding: Bool) {
        guard !highlights.isEmpty else { return }
        for highlight in highlights {
            if adding { highlight.page.addAnnotation(highlight.annotation) }
            else { highlight.page.removeAnnotation(highlight.annotation) }
        }
        undoManager?.registerUndo(withTarget: self) { target in target.apply(highlights, adding: !adding) }
        undoManager?.setActionName(adding ? "형광펜 표시" : "형광펜 지우기")
        // NSDocument tracks change counts through its undo manager notifications.
        // Incrementing here as well would leave a fully undone document dirty.
        if undoManager == nil { updateChangeCount(.changeDone) }
        for controller in windowControllers {
            (controller as? ReaderWindowController)?.pdfView.needsDisplay = true
        }
    }
}
