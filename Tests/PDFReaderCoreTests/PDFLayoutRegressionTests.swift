import AppKit
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFLayoutRegressionTests {
    typealias Row = PDFIntegrationTests.Row

    @Test func dropCapDoesNotSplitAWordOrAddSpacesFromTheNextLine() throws {
        let pdf = PDFSpacingTests.makePDF(content: #"/F1 28 Tf 1 0 0 1 50 704 Tm (I) Tj /F1 12 Tf 1 0 0 1 67 720 Tm (MAGE quality assessment) Tj 1 0 0 1 67 702 Tm [(is)-200(a)-200(useful)-200(measure.)] TJ"#)
        let selection = try #require(pdf.selectionForEntireDocument)
        #expect(PDFTextExtractor.clean(selection) == "IMAGE quality assessment is a useful measure.")
    }

    @Test func detachedDropCapJoinsOnlyWhenSelected() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "A", y: 704, size: 30),
            Row(text: "rtificial intelligence", x: 71.5, y: 720),
            Row(text: "supports research.", x: 71.5, y: 703)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "Artificial intelligence supports research.")
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let range = text.range(of: "rtificial intelligence")
        #expect(PDFTextExtractor.clean(try #require(page.selection(for: range))) == "rtificial intelligence")
    }

    @Test func interleavedFooterIsOmittedButAnExplicitFootnoteSelectionIsKept() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "The method compares", y: 148),
            Row(text: "photographs of human", y: 131),
            Row(text: "1 Author affiliation and project information.", y: 106, size: 9),
            Row(text: "faces using visual features", x: 330, y: 180),
            Row(text: "and measured quality.", x: 330, y: 163)
        ]])
        let page = try #require(pdf.page(at: 0))
        let raw = try #require(page.string) as NSString
        let start = raw.range(of: "The method").location
        let end = NSMaxRange(raw.range(of: "and measured quality."))
        let body = try #require(page.selection(for: NSRange(location: start, length: end - start)))
        #expect(try #require(body.string).contains("Author affiliation"))
        #expect(PDFTextExtractor.clean(body) == "The method compares photographs of human faces using visual features and measured quality.")
        let footnote = try #require(page.selection(for: raw.range(of: "1 Author affiliation and project information.")))
        #expect(PDFTextExtractor.clean(footnote) == "1 Author affiliation and project information.")
    }

    @Test func smallerTextWithinTheSameColumnIsNotDeleted() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "A body paragraph introduces", y: 150),
            Row(text: "a quotation.", y: 133),
            Row(text: "Quoted text remains part of the copy.", y: 108, size: 9),
            Row(text: "The body continues below.", y: 80)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)).contains("Quoted text remains part of the copy."))
    }

    @Test func inlineNumberedClausesStayInTheParagraph() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "Our goals are (1) accuracy, (2) speed,", y: 720),
            Row(text: "(3) accessibility for everyone.", y: 703)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "Our goals are (1) accuracy, (2) speed, (3) accessibility for everyone.")
    }

    @Test func hyphenationUsesWholeWordsAndDocumentSpelling() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "A deblurring method uses real-time processing.", y: 750),
            Row(text: "We are often adapting models.", y: 733),
            Row(text: "The deblur-", y: 700), Row(text: "ring model is of-", y: 683),
            Row(text: "ten adapt-", y: 666), Row(text: "ing mod-", y: 649),
            Row(text: "els using ResNet-", y: 632), Row(text: "like real-", y: 615),
            Row(text: "time processing.", y: 598)
        ]])
        let page = try #require(pdf.page(at: 0))
        let text = try #require(page.string) as NSString
        let start = text.range(of: "The deblur-").location
        let selection = try #require(page.selection(for: NSRange(location: start, length: text.length - start)))
        #expect(PDFTextExtractor.clean(selection) == "The deblurring model is often adapting models using ResNet-like real-time processing.")
    }

    @Test func overlappingAccentIsComposedWithoutChangingLiteralAccents() throws {
        let pdf = PDFSpacingTests.makePDF(content: #"(Wysocza) Tj 1 0 0 1 100.4 720 Tm (\264) Tj 1 0 0 1 100.4 720 Tm (nska) Tj 1 0 0 1 50 702 Tm (A literal \264 mark remains.) Tj"#)
        let selection = try #require(pdf.selectionForEntireDocument)
        #expect(PDFTextExtractor.clean(selection) == "Wysoczańska A literal ´ mark remains.")
    }

    @Test func superscriptDoesNotSplitProseIntoParagraphs() throws {
        let body = "We describe this method"
        let lastX = 50 + (body as NSString).size(withAttributes: [.font: NSFont(name: "TimesNewRomanPSMT", size: 12)!]).width
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: body, y: 720),
            Row(text: "1", x: lastX, y: 725, size: 8),
            Row(text: ".", x: lastX + 4, y: 720),
            Row(text: "The next sentence stays in the paragraph.", y: 703)
        ]])
        let text = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(text == "We describe this method1. The next sentence stays in the paragraph.")
    }

    @Test func completeColumnsKeepTheirReadingOrder() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "First column begins", x: 50, y: 720),
            Row(text: "and continues", x: 50, y: 703),
            Row(text: "in the second column", x: 330, y: 720),
            Row(text: "before it ends.", x: 330, y: 703)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "First column begins and continues in the second column before it ends.")
    }
    @Test func reverseAndInterleavedDrawingOrderCopiesInVisualOrder() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "in its intended order.", y: 686),
            Row(text: "The first line continues", y: 720),
            Row(text: "across the second line", y: 703)
        ]])
        #expect(PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument)) == "The first line continues across the second line in its intended order.")
    }

    @Test func overlappingSubscriptsDoNotCreateParagraphs() throws {
        let pdf = PDFSpacingTests.makePDF(content: #"(where D) Tj /F1 8 Tf 1 0 0 1 100.4 724 Tm (T) Tj 1 0 0 1 100.4 718 Tm (x) Tj /F1 12 Tf 1 0 0 1 109 720 Tm (is the operator) Tj 1 0 0 1 50 702 Tm (used in the model.) Tj"#)
        let result = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(!result.contains("\n"))
        #expect(result.contains("is the operator used in the model."))
    }

    @Test func modestReferenceSpacingPreservesEntryBoundaries() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            Row(text: "Khan, A. 2024. A paper about vision and", y: 720),
            Row(text: "learning across many image datasets.", y: 706),
            Row(text: "Published in a computer vision conference.", y: 692),
            Row(text: "Kirillov, A. 2023. A paper about models", y: 674.5),
            Row(text: "that segment images with a prompt.", y: 660.5),
            Row(text: "Published in a computer vision conference.", y: 646.5)
        ]])
        let result = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(result.contains("conference.\n\nKirillov"))
        #expect(result.components(separatedBy: "\n\n").count == 2)
    }

    @Test func stackedFractionStaysAfterItsLeftHandSide() throws {
        let pdf = PDFSpacingTests.makePDF(content: #"1 0 0 1 50 710 Tm (Accuracy =) Tj 1 0 0 1 170 719 Tm (A + B) Tj 1 0 0 1 150 703 Tm (A + B + C) Tj"#)
        let result = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(result.hasPrefix("Accuracy ="))
        #expect(result.range(of: "A + B")!.lowerBound < result.range(of: "A + B + C")!.lowerBound)
    }

    @Test func tallInlineSymbolUsesBodyBaselineForParagraphsAndSpaces() throws {
        let pdf = PDFSpacingTests.makePDF(content: #"(The text continues with a) Tj 1 0 0 1 224 724 Tm (T) Tj 1 0 0 1 232 720 Tm (symbol) Tj 1 0 0 1 50 702 Tm (and remains one paragraph.) Tj"#)
        let result = PDFTextExtractor.clean(try #require(pdf.selectionForEntireDocument))
        #expect(!result.contains("\n"))
        #expect(result.hasSuffix("and remains one paragraph."))
    }

}
