import AppKit
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFSpacingTests {
    /// Unlike CoreText's output, this fixture has no literal space characters.
    /// Its TJ adjustments reproduce the narrow word gaps PDFKit drops.
    static func makePDF(content: String, transform: String = "", form: Bool = false) -> PDFDocument {
        let widths = Array(repeating: "600", count: 224).joined(separator: " ")
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255 /Widths [\(widths)] >>"
        let text = "BT /F1 12 Tf 1 0 0 1 50 720 Tm \(content) ET"
        let stream = form ? "q \(transform) /Form1 Do Q" : "q \(transform) \(text) Q"
        let resources = form ? "/XObject << /Form1 6 0 R >>" : "/Font << /F1 4 0 R >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << \(resources) >> /Contents 5 0 R >>",
            font,
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        if form {
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Matrix [1 0 0 1 10 0] /Resources << /Font << /F1 4 0 R >> >> /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream")
        }
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return PDFDocument(data: Data(pdf.utf8))!
    }

    @Test func restoresPositionedWordSpacesThroughClipboard() throws {
        _ = NSApplication.shared
        let pdf = Self.makePDF(content: #"[(some)-200(of)-200(their)-200(design)-200(choices)] TJ 0 -18 Td [(2\327)-200(faster)-200(and)-200(3\327)-200(less)] TJ"#)
        let selection = try #require(pdf.selectionForEntireDocument)
        #expect(selection.string == "someoftheirdesignchoices\n2×fasterand3×less")
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.document = pdf
        view.currentSelection = selection
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.copySelection(corrected: true, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "some of their design choices 2× faster and 3× less")
        #expect(view.copySelection(corrected: false, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == selection.string)
    }

    @Test func preservesKerningTrackingAndPartialSelection() throws {
        let pdf = Self.makePDF(content: "0.3 Tc [(prefix)-200(de)-28(sign)-200(choices)-200(suffix)] TJ")
        let page = try #require(pdf.page(at: 0))
        let raw = try #require(page.string) as NSString
        let range = raw.range(of: "designchoices")
        #expect(range.location != NSNotFound)
        let selection = try #require(page.selection(for: range))
        #expect(PDFTextExtractor.clean(selection) == "design choices")
    }

    @Test func restoresSpacesAfterTextPositionAndFontChanges() throws {
        let pdf = Self.makePDF(content: #"(2\327) Tj /F1 12 Tf 16.8 0 Td (faster) Tj ET BT /F1 12 Tf 1 0 0 1 112.4 720 Tm (now) Tj"#)
        let selection = try #require(pdf.selectionForEntireDocument)
        #expect(PDFTextExtractor.clean(selection) == "2× faster now")
    }

    @Test(arguments: [false, true])
    func restoresSpacesInTransformedContent(form: Bool) throws {
        let pdf = Self.makePDF(content: "[(some)-200(words)] TJ", transform: "0.8 0 0 0.8 20 50 cm", form: form)
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "some words")
    }
    @Test func restoresWordSpaceAfterReturningFromASubscript() throws {
        let pdf = Self.makePDF(content: #"(stack S) Tj /F1 8 Tf 1 0 0 1 100.4 718 Tm (L) Tj /F1 12 Tf 1 0 0 1 107.6 720 Tm (and reflectance.) Tj"#)
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "stack SL and reflectance.")
    }

}
