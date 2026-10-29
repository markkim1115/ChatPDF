import AppKit
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFSelectionRepairTests {
    private func point(_ text: String, on page: PDFPage, end: Bool = false) throws -> CGPoint {
        let range = try #require(page.string as NSString?).range(of: text)
        #expect(range.location != NSNotFound)
        let box = try #require(page.selection(for: NSRange(location: end ? NSMaxRange(range) - 1 : range.location, length: 1))).bounds(for: page)
        return CGPoint(x: end ? box.maxX : box.minX, y: box.midY)
    }

    @Test func narrowColumnsStaySeparateInBothDragDirections() throws {
        let left = ["First selected line continues", "Second selected line follows", "The last selected line ends."]
        let probe = PDFIntegrationTests.makePDF([[.init(text: left[0], y: 720)]])
        let rightX = try #require(probe.selectionForEntireDocument).bounds(for: probe.page(at: 0)!).maxX + 12
        let pdf = PDFIntegrationTests.makePDF([left.enumerated().flatMap { index, text in [
            PDFIntegrationTests.Row(text: text, y: 720 - CGFloat(index) * 17),
            .init(text: "Other column must stay out.", x: rightX, y: 720 - CGFloat(index) * 17)
        ] }])
        let page = try #require(pdf.page(at: 0))
        let a = try point(left[0], on: page), b = try point(left[2], on: page, end: true)
        for (start, end) in [(a, b), (b, a)] {
            let selection = try #require(PDFSelectionRepair.selection(on: page, from: start, to: end))
            #expect(PDFTextExtractor.clean(selection) == left.joined(separator: " "))
            #expect(selection.selectionsByLine().allSatisfy { $0.bounds(for: page).maxX < rightX })
            #expect(Highlights.make(for: selection, color: .yellow).allSatisfy { $0.annotation.bounds.maxX < rightX })
        }
        let rightA = CGPoint(x: rightX, y: a.y), rightB = CGPoint(x: rightX + 130, y: b.y)
        let right = try #require(PDFSelectionRepair.selection(on: page, from: rightA, to: rightB))
        #expect(right.selectionsByLine().allSatisfy { $0.bounds(for: page).minX >= rightX - 0.1 })
        #expect(PDFSelectionRepair.selection(on: page, from: a, to: rightB) == nil)
    }

    @Test func shortEndpointsDoNotOmitFullWidthMiddleLines() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Start here", y: 720),
            .init(text: "This much longer middle line must be selected.", y: 703),
            .init(text: "End here", y: 686),
            .init(text: "Other column", x: 330, y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let result = try #require(PDFSelectionRepair.selection(on: page,
            from: try point("Start here", on: page), to: try point("End here", on: page, end: true)))
        #expect(result.string?.contains("This much longer middle line must be selected.") == true)
        #expect(result.string?.contains("Other column") == false)
    }

    @Test func partialAndSingleLineSelectionsRespectCharacterEndpoints() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Prefix. Selected text", y: 720),
            .init(text: "continues here. Suffix.", y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let a = try point("Selected", on: page), b = try point("continues here.", on: page, end: true)
        let result = try #require(PDFSelectionRepair.selection(on: page, from: a, to: b))
        #expect(PDFTextExtractor.clean(result) == "Selected text continues here.")
        let c = try point("Selected text", on: page, end: true)
        let single = try #require(PDFSelectionRepair.selection(on: page, from: c, to: a))
        #expect(single.string == "Selected text")
    }

    @Test func centeredHeadingKeepsEveryBodyLineInItsColumn() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Introduction", x: 130, y: 720),
            .init(text: "The first body line must remain selected.", y: 700),
            .init(text: "The middle line remains selected too.", y: 683),
            .init(text: "The final body line ends here.", y: 666),
            .init(text: "Another column must stay out.", x: 330, y: 700),
            .init(text: "Its next line must also stay out.", x: 330, y: 683)
        ]])
        let page = try #require(pdf.page(at: 0))
        let a = try point("Introduction", on: page), b = try point("The final body line ends here.", on: page, end: true)
        for (start, end) in [(a, b), (b, a)] {
            let result = try #require(PDFSelectionRepair.selection(on: page, from: start, to: end)
                ?? pdf.selection(from: page, at: start, to: page, at: end))
            #expect(result.string?.contains("The first body line must remain selected.") == true)
            #expect(result.string?.contains("The middle line remains selected too.") == true)
            #expect(result.string?.contains("Another column") == false)
        }
    }

    @Test func detachedSentenceFragmentsStayInTheColumnInBothDirections() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Cited in [1].", y: 720),
            .init(text: "The sentence continues", x: 118, y: 720),
            .init(text: "and ends on this line.", y: 703),
            .init(text: "Another column starts here", x: 330, y: 720),
            .init(text: "and must stay unselected.", x: 330, y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let a = try point("Cited in [1].", on: page), b = try point("and ends on this line.", on: page, end: true)
        for (start, end) in [(a, b), (b, a)] {
            let selection = try #require(PDFSelectionRepair.selection(on: page, from: start, to: end))
            #expect(PDFTextExtractor.clean(selection) == "Cited in [1]. The sentence continues and ends on this line.")
        }
        let across = try #require(PDFSelectionRepair.selection(on: page, from: a,
            to: try point("Another column starts here", on: page, end: true)))
        #expect(across.string?.contains("Another column starts here") == true)
        #expect(across.string?.contains("ends on this line") == false)
    }

    @Test func erasingOneLineKeepsNeighboringHighlightsAfterReopening() throws {
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Keep the upper line", y: 720),
            .init(text: "Erase only the middle line", y: 708),
            .init(text: "Keep the lower line", y: 696)
        ]])
        let originalData = try #require(pdf.dataRepresentation())
        let reopened = try #require(PDFDocument(data: originalData))
        for document in [pdf, reopened] {
            let page = try #require(document.page(at: 0))
            let lines = try #require(document.selectionForEntireDocument).selectionsByLine()
            let marks = lines.flatMap { Highlights.make(for: $0, color: .yellow) }
            #expect(marks.count == 3)
            marks.forEach { $0.page.addAnnotation($0.annotation) }
            let middle = try #require(lines.first { $0.string == "Erase only the middle line" })
            let hits = Highlights.intersecting(middle)
            #expect(hits.count == 1)
            hits.forEach { $0.page.removeAnnotation($0.annotation) }
            let data = try #require(document.dataRepresentation())
            let saved = try #require(PDFDocument(data: data))
            #expect(saved.page(at: 0)?.annotations.map(\.contents).compactMap { $0 }.sorted()
                == ["Keep the lower line", "Keep the upper line"])
        }
    }

    @Test func dragUpdatesSelectionBeforeMouseUpAndSupportsHighlightDeletion() throws {
        _ = NSApplication.shared
        let pdf = PDFIntegrationTests.makePDF([[
            .init(text: "Select this first line", y: 720), .init(text: "and this second line.", y: 703),
            .init(text: "Do not select this", x: 330, y: 720), .init(text: "or this other line.", x: 330, y: 703)
        ]])
        let page = try #require(pdf.page(at: 0))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 612, height: 792), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ReaderPDFView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.document = pdf
        view.layoutDocumentView()
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let location = view.convert(view.convert(point, from: page), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let a = try point("Select", on: page), b = try point("and this second line.", on: page, end: true)
        for scale in [1.0, 2.85, 0.75, 2.0, 1.0] {
            view.scaleFactor = scale
            view.layoutDocumentView()
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 792)))
            #expect(view.handleSelectionEvent(event(.leftMouseDown, a)) == nil)
            #expect(view.handleSelectionEvent(event(.leftMouseDragged, b)) == nil)
            #expect(PDFTextExtractor.clean(try #require(view.currentSelection)) == "Select this first line and this second line.")
            #expect(view.handleSelectionEvent(event(.leftMouseUp, b)) == nil)
        }
        let selected = try #require(view.currentSelection)
        #expect(PDFTextExtractor.clean(selected) == "Select this first line and this second line.")
        let marks = Highlights.make(for: selected, color: .yellow)
        marks.forEach { $0.page.addAnnotation($0.annotation) }
        view.clearSelection()
        let hit = marks[0].annotation.bounds
        let click = CGPoint(x: hit.midX, y: hit.midY)
        #expect(view.handleSelectionEvent(event(.leftMouseDown, click)) == nil)
        #expect(view.handleSelectionEvent(event(.leftMouseUp, click)) == nil)
        #expect(view.highlightsToRemove.count == 1)
        view.removeHighlights = { view.highlightsToRemove.forEach { $0.page.removeAnnotation($0.annotation) }; view.clearSelection() }
        let delete = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        #expect(view.handleSelectionEvent(delete) == nil)
        #expect(page.annotations.count == marks.count - 1)
    }

    @Test func cachedSelectionLayoutSurvivesZoomButNotDocumentOrPageChanges() throws {
        _ = NSApplication.shared
        let pdf = PDFIntegrationTests.makePDF([[.init(text: "First document", y: 720)]])
        let page = try #require(pdf.page(at: 0))
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        view.document = pdf
        let layout = try #require(view.selectionLayout(on: page))
        view.scaleFactor = 2.85
        #expect(view.selectionLayout(on: page) === layout)
        page.rotation = 90
        #expect(view.selectionLayout(on: page) == nil)
        page.rotation = 0
        let rotatedBack = try #require(view.selectionLayout(on: page))
        #expect(rotatedBack !== layout)
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 792), for: .cropBox)
        #expect(view.selectionLayout(on: page) !== rotatedBack)

        let replacement = PDFIntegrationTests.makePDF([[.init(text: "Replacement document", y: 720)]])
        view.document = replacement
        let replacementPage = try #require(replacement.page(at: 0))
        let result = try #require(view.selectionLayout(on: replacementPage)?.selection(
            from: try point("Replacement document", on: replacementPage),
            to: try point("Replacement document", on: replacementPage, end: true)))
        #expect(result.string == "Replacement document")
        weak var releasedPDF: PDFDocument?
        autoreleasepool {
            let temporary = PDFIntegrationTests.makePDF([[.init(text: "Temporary", y: 720)]])
            releasedPDF = temporary
            view.document = temporary
            _ = view.selectionLayout(on: temporary.page(at: 0)!)
            view.document = nil
        }
        #expect(releasedPDF == nil)
    }

    @Test func markupHitTestingUsesQuadsInsteadOfOuterBounds() throws {
        let pdf = PDFIntegrationTests.makePDF([[.init(text: "Unhighlighted text in gap", x: 160, y: 710)]])
        let page = try #require(pdf.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 400, height: 30), forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = [CGPoint(x: 0, y: 30), CGPoint(x: 70, y: 30), CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 0),
            CGPoint(x: 300, y: 30), CGPoint(x: 400, y: 30), CGPoint(x: 300, y: 0), CGPoint(x: 400, y: 0)].map { NSValue(point: $0) }
        page.addAnnotation(annotation)
        #expect(Highlights.at(CGPoint(x: 60, y: 715), on: page)?.annotation === annotation)
        #expect(Highlights.at(CGPoint(x: 200, y: 715), on: page) == nil)
        #expect(Highlights.intersecting(try #require(pdf.selectionForEntireDocument)).isEmpty)
        let data = try #require(pdf.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        #expect(Highlights.at(CGPoint(x: 60, y: 715), on: reopened.page(at: 0)!) != nil)
    }

    @Test func toolbarClickKeepsASelectedHighlightWithoutText() throws {
        _ = NSApplication.shared
        let pdf = PDFIntegrationTests.makePDF([[]])
        let page = try #require(pdf.page(at: 0))
        let mark = PDFAnnotation(bounds: CGRect(x: 100, y: 500, width: 100, height: 15), forType: .highlight, withProperties: nil)
        page.addAnnotation(mark)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 612, height: 792), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 700))
        window.contentView!.addSubview(view)
        view.document = pdf
        view.layoutDocumentView()
        let click = view.convert(view.convert(CGPoint(x: 150, y: 507), from: page), to: nil)
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        _ = view.handleSelectionEvent(event(.leftMouseDown, at: click))
        _ = view.handleSelectionEvent(event(.leftMouseUp, at: click))
        #expect(view.highlightsToRemove.first?.annotation === mark)
        #expect(view.handleSelectionEvent(event(.leftMouseDown, at: CGPoint(x: 20, y: 760))) != nil)
        #expect(view.highlightsToRemove.first?.annotation === mark)
    }

    @Test func overlappingHighlightBoundsUseTheClickedLine() throws {
        let pdf = PDFIntegrationTests.makePDF([[]])
        let page = try #require(pdf.page(at: 0))
        let lower = PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 200, height: 12), forType: .highlight, withProperties: nil)
        let upper = PDFAnnotation(bounds: CGRect(x: 50, y: 104, width: 200, height: 19), forType: .highlight, withProperties: nil)
        page.addAnnotation(lower)
        page.addAnnotation(upper)
        #expect(Highlights.at(CGPoint(x: 100, y: 106), on: page)?.annotation === lower)
        #expect(Highlights.at(CGPoint(x: 100, y: 114), on: page)?.annotation === upper)
    }
}
