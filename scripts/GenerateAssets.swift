import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("build/.staging.noindex/ChatPDF.app/Contents/Resources")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// A small vector drawing produces all Retina icon sizes without image assets.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.28, blue: 0.39, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.23, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 264, y: 199, width: 496, height: 646), xRadius: 44, yRadius: 44).fill()
        NSColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 312, y: 450, width: 400, height: 85), xRadius: 9, yRadius: 9).fill()
        NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.39, alpha: 1).setFill()
        for (y, width) in [(687, 226), (591, 362), (485, 362), (389, 310), (293, 362)] {
            NSBezierPath(roundedRect: NSRect(x: 332, y: y, width: width, height: 18), xRadius: 9, yRadius: 9).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
    }
}

var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdfURL = resources.appendingPathComponent("Reading Guide.pdf")
let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, [kCGPDFContextTitle: "A clearer way to read", kCGPDFContextAuthor: "ChatPDF"] as CFDictionary)!
let ink = CGColor(red: 0.12, green: 0.20, blue: 0.27, alpha: 1)
let muted = CGColor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1)

func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, font: String = "Helvetica", color: CGColor = ink) {
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs)), context)
}
func rule(_ y: CGFloat) {
    context.setStrokeColor(CGColor(gray: 0.84, alpha: 1))
    context.setLineWidth(0.5)
    context.move(to: CGPoint(x: 58, y: y)); context.addLine(to: CGPoint(x: 554, y: y)); context.strokePath()
}
func footer(_ page: Int) {
    rule(54)
    text("CHATPDF  /  READING GUIDE", 58, 35, size: 8, color: muted)
    text(String(format: "%02d", page), 540, 35, size: 9, color: muted)
}
context.beginPDFPage(nil)
text("CHATPDF", 58, 734, size: 10, font: "Helvetica-Bold")
text("A LITTLE LESS FRICTION", 376, 734, size: 9, color: muted)
rule(713)
text("A clearer way", 58, 647, size: 43, font: "Helvetica-Bold")
text("to read.", 58, 598, size: 43, font: "Helvetica-Bold")
context.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.32, alpha: 1))
context.fill(CGRect(x: 58, y: 565, width: 56, height: 5))
text("Your document, just as it should look.", 58, 535, size: 14, color: muted)
text("Your words, ready to go wherever you write.", 58, 514, size: 14, color: muted)
text("01  /  COPY WITHOUT THE LINE BREAKS", 58, 454, size: 10, font: "Helvetica-Bold")
text("Select the paragraph below and press Command-C. Paste it into", 58, 428, size: 11, color: muted)
text("any text editor: the visual line breaks become a flowing paragraph.", 58, 412, size: 11, color: muted)
let example = [
    "As illustrated in Fig. 2 (b), the dual-branch network is",
    "built upon the UNet architecture, involving an encoder and",
    "an decoder with respective three Lighten Cross-Attention",
    "(LCA) modules, and multiple skip connections. Two key",
    "designs in the network are the dual-branch structure and the",
    "LCA module. We explain the key intuition behind these",
    "designs as follows."
]
for (index, line) in example.enumerated() { text(line, 74, 370 - CGFloat(index) * 18, size: 13, font: "TimesNewRomanPSMT") }
context.setFillColor(CGColor(red: 0.89, green: 0.92, blue: 0.94, alpha: 1))
context.fill(CGRect(x: 58, y: 259, width: 2, height: 125))
text("02  /  KEEP WHAT MATTERS", 58, 208, size: 10, font: "Helvetica-Bold")
text("Select a sentence. Click the highlighter, or press Shift-Command-H.", 58, 182, size: 11, color: muted)
text("Choose a color, save with Command-S, and open it in Preview.", 58, 166, size: 11, color: muted)
text("The highlights stay with your PDF.", 58, 150, size: 11, color: muted)
footer(1)
context.endPDFPage()

context.beginPDFPage(nil)
text("SPACE TO THINK", 58, 734, size: 10, font: "Helvetica-Bold")
text("02  /  THE DETAILS", 432, 734, size: 9, color: muted)
rule(713)
text("Made for focused reading.", 58, 655, size: 28, font: "Helvetica-Bold")
text("Familiar controls. Thoughtful defaults.", 58, 626, size: 13, color: muted)
let sections: [(String, [String])] = [
    ("FLOWING TEXT", ["A PDF places words on a page. Its", "visual lines are not always meaningful", "when those words move elsewhere.", "", "Copy correction joins wrapped lines", "while keeping paragraphs and lists.", "Real compound words keep their", "hyphens. A word broken by typesetting", "is repaired when a dictionary can", "confirm the complete word."]),
    ("YOUR ORIGINAL, PRESERVED", ["Need the exact extracted text? Use", "Shift-Command-C to keep the original", "line breaks for this copy.", "", "The correction toggle changes only", "what goes onto the clipboard. It does", "not rewrite the contents of your PDF.", "", "Highlights are standard PDF annotations.", "Save a separate copy with", "Shift-Command-S whenever you like."])
]
for (column, section) in sections.enumerated() {
    let x: CGFloat = column == 0 ? 58 : 322
    text(section.0, x, 567, size: 10, font: "Helvetica-Bold")
    for (index, line) in section.1.enumerated() { text(line, x, 538 - CGFloat(index) * 17, size: 11, font: "TimesNewRomanPSMT") }
}
rule(304)
text("A FEW USEFUL SHORTCUTS", 58, 275, size: 10, font: "Helvetica-Bold")
let shortcuts = [("Command-O", "Open a PDF"), ("Command-F", "Find in the document"), ("Command-0", "Fit the page to the window"), ("Shift-Command-H", "Highlight the selected text"), ("Command-Z", "Undo a highlight")]
for (index, row) in shortcuts.enumerated() {
    text(row.0, 58, 244 - CGFloat(index) * 27, size: 11, font: "Menlo-Regular")
    text(row.1, 280, 244 - CGFloat(index) * 27, size: 11, color: muted)
}
footer(2)
context.endPDFPage()
context.closePDF()
print("Generated app icon and selectable Reading Guide.pdf")
