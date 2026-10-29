import AppKit
import CoreText
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFIntegrationTests {
    struct Row {
        let text: String
        var x: CGFloat = 50
        let y: CGFloat
        var size: CGFloat = 12
    }

    static func makePDF(_ pages: [[Row]]) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for rows in pages {
            context.beginPDFPage(nil)
            for row in rows {
                let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, row.size, nil)
                let value = NSAttributedString(string: row.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: row.x, y: row.y)
                CTLineDraw(CTLineCreateWithAttributedString(value), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    @Test func testRealPDFSelectionCleansUserExample() throws {
        let rows = TextCleanerTests.example.components(separatedBy: "\n").enumerated().map { Row(text: $0.element, y: 720 - CGFloat($0.offset) * 17) }
        let pdf = Self.makePDF([rows])
        let selection = try #require(pdf.selectionForEntireDocument)
        #expect(try #require(selection.string).contains("\n"))
        #expect(PDFTextExtractor.clean(selection) == TextCleanerTests.example.replacingOccurrences(of: "\n", with: " "))
    }

    @Test func testRealPDFParagraphSpacingIsPreserved() throws {
        let pdf = Self.makePDF([[
            Row(text: "This is the first paragraph and it", y: 720),
            Row(text: "continues on the next visual line.", y: 703),
            Row(text: "This is a second paragraph that", y: 667),
            Row(text: "also continues on the next line.", y: 650)
        ]])
        let text = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(text == "This is the first paragraph and it continues on the next visual line.\n\nThis is a second paragraph that also continues on the next line.")
    }

    @Test func testHeadingsAreNotMergedIntoBody() throws {
        let pdf = Self.makePDF([[
            Row(text: "A heading", y: 720, size: 22),
            Row(text: "Body text wraps across", y: 690),
            Row(text: "two lines on the page.", y: 673)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "A heading\n\nBody text wraps across two lines on the page.")
    }

    @Test func testPartialSelectionDoesNotCopyUnselectedText() throws {
        let pdf = Self.makePDF([[
            Row(text: "Unselected prefix. Selected text", y: 720),
            Row(text: "continues here. Unselected suffix.", y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let raw = try #require(page.string) as NSString
        let start = raw.range(of: "Selected text").location
        let end = NSMaxRange(raw.range(of: "continues here."))
        let selection = try #require(page.selection(for: NSRange(location: start, length: end - start)))
        #expect(PDFTextExtractor.clean(selection) == "Selected text continues here.")
    }

    @Test func testCrossPageContinuation() throws {
        let pdf = Self.makePDF([[Row(text: "A sentence continues onto", y: 70)], [Row(text: "the next page without a break.", y: 720)]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "A sentence continues onto the next page without a break.")
    }

    @Test func testDictionaryRepairsTypesetWordInRealPDF() throws {
        let pdf = Self.makePDF([[Row(text: "The architec-", y: 720), Row(text: "ture has a dual-branch design.", y: 703)]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "The architecture has a dual-branch design.")
    }

    @Test func testOneColumnSelectionDoesNotIncludeAdjacentColumn() throws {
        let pdf = Self.makePDF([[
            Row(text: "The selected column has", x: 50, y: 720),
            Row(text: "text that flows across lines.", x: 50, y: 703),
            Row(text: "This other column must", x: 330, y: 720),
            Row(text: "not appear in the copy.", x: 330, y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let selection = try #require(page.selection(for: CGRect(x: 48, y: 698, width: 220, height: 36)))
        #expect(PDFTextExtractor.clean(selection) == "The selected column has text that flows across lines.")
        #expect(Highlights.make(for: selection, color: .systemYellow).allSatisfy { $0.annotation.bounds.maxX < 300 })
    }

    @Test func testLockedAndCopyRestrictedDocumentsLeaveClipboardUntouched() throws {
        _ = NSApplication.shared
        let source = Self.makePDF([[Row(text: "Restricted document", y: 720)]])
        let options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: "owner-test", .userPasswordOption: "reader-test", .accessPermissionsOption: 0]
        let data = try #require(source.dataRepresentation(options: options))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.isLocked)
        #expect(pdf.unlock(withPassword: "reader-test"))
        #expect(!pdf.allowsCopying)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = pdf
        view.currentSelection = pdf.selectionForEntireDocument
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep this clipboard", forType: .string)
        #expect(!view.copySelection(corrected: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
    }

    @Test func testClipboardOffersOnlyCorrectedPlainTextAndCanCopyOriginal() throws {
        _ = NSApplication.shared
        let pdf = Self.makePDF([[Row(text: "First visual line", y: 720), Row(text: "and the next line.", y: 703)]])
        let selection = try #require(pdf.selectionForEntireDocument)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = pdf
        view.currentSelection = selection
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old rich text", forType: .rtf)
        #expect(view.copySelection(corrected: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "First visual line and the next line.")
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(view.copySelection(corrected: false, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == selection.string)
        view.clearSelection()
        #expect(!(view.copySelection(corrected: true, to: pasteboard)))
        #expect(pasteboard.string(forType: .string) == selection.string)
    }

    @Test func testHighlightsSurvivePDFSerializationAndStayOnTheirLines() throws {
        let pdf = Self.makePDF([[Row(text: "First highlighted line", y: 720), Row(text: "second highlighted line.", y: 703)]])
        let selection = try #require(pdf.selectionForEntireDocument)
        let highlights = Highlights.make(for: selection, color: .systemYellow)
        #expect(highlights.count == 2)
        highlights.forEach { $0.page.addAnnotation($0.annotation) }
        #expect(highlights.allSatisfy { $0.annotation.bounds.height < 20 })
        let data = try #require(pdf.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        let page = try #require(reopened.page(at: 0))
        #expect(page.annotations.filter { $0.type == "Highlight" }.count == 2)
        let found = Highlights.intersecting(try #require(reopened.selectionForEntireDocument))
        #expect(found.count == 2)
        found.forEach { $0.page.removeAnnotation($0.annotation) }
        #expect(page.annotations.isEmpty)
        #expect(reopened.string == pdf.string)
    }
}
