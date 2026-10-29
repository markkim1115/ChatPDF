import AppKit
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFOCRTests {
    @Test func imageOnlyParagraphCanBeRecognizedAndPasted() throws {
        let source = PDFIntegrationTests.makePDF([[
            .init(text: "This scanned paragraph continues", y: 720, size: 18),
            .init(text: "on the next line of the document.", y: 694, size: 18)
        ]])
        let original = try #require(source.page(at: 0))
        let region = CGRect(x: 40, y: 682, width: 450, height: 62)
        let image = try PDFOCR.render(page: original, region: region)
        let scan = try #require(PDFPage(image: NSImage(cgImage: image, size: region.size)))
        let pdf = PDFDocument()
        pdf.insert(scan, at: 0)
        #expect((scan.string ?? "").isEmpty)
        let pixels = try PDFOCR.render(page: scan, region: scan.bounds(for: .cropBox))
        let lines = try PDFOCR.recognize(pixels)
        let text = PDFTextExtractor.cleanRecognized(lines, in: scan.bounds(for: .cropBox), on: scan)
        #expect(text == "This scanned paragraph continues on the next line of the document.")
        let board = NSPasteboard(name: .init("org.pdfreader.ocr-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(board.setString(text, forType: .string))
        let destination = NSTextView(frame: .zero)
        #expect(destination.readSelection(from: board, type: .string))
        #expect(destination.string == text)
    }

    @Test func cropOffsetExcludesUnselectedWords() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Selected text remains readable.", x: 70, y: 690, size: 18),
            .init(text: "Excluded sentence must stay outside.", x: 70, y: 630, size: 18)
        ]])
        let page = try #require(pdf.page(at: 0))
        page.setBounds(CGRect(x: 40, y: 600, width: 500, height: 150), for: .cropBox)
        let nativeRegion = CGRect(x: 60, y: 680, width: 350, height: 32)
        let region = nativeRegion.applying(page.transform(for: .cropBox))
        let lines = try PDFOCR.recognize(PDFOCR.render(page: page, region: region))
        #expect(lines.map(\.text).joined(separator: " ") == "Selected text remains readable.")
    }

    @Test func copyRestrictionsAndEmptyRegionsAreNotBypassed() throws {
        let source = PDFIntegrationTests.makePDF([[.init(text: "Restricted text", y: 720)]])
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "owner", .userPasswordOption: "reader", .accessPermissionsOption: 0
        ]
        let data = try #require(source.dataRepresentation(options: options))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.unlock(withPassword: "reader"))
        let page = try #require(pdf.page(at: 0))
        #expect(throws: PDFOCR.Failure.self) { try PDFOCR.render(page: page, region: page.bounds(for: .cropBox)) }
        let allowed = try #require(source.page(at: 0))
        #expect(throws: PDFOCR.Failure.self) { try PDFOCR.render(page: allowed, region: .zero) }
        let empty = try PDFOCR.render(page: allowed, region: CGRect(x: 50, y: 50, width: 200, height: 100))
        #expect(throws: PDFOCR.Failure.self) { try PDFOCR.recognize(empty) }
    }
}
