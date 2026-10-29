import Foundation
import PDFKit

/// PDF text often encodes a word space as a positioning adjustment, not a
/// character. PDFKit drops small justified spaces. Read the original glyph
/// advances to locate those gaps without guessing how words should be spelled.
final class PDFWordSpacing {
    private struct FontWidths {
        var widths: [Int: CGFloat]
        var defaultWidth: CGFloat?
        var codeBytes: Int

        init?(_ dictionary: CGPDFDictionaryRef) {
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return nil }
            var font = dictionary
            if String(cString: subtype) == "Type0" {
                var encoding: UnsafePointer<CChar>?
                var descendants: CGPDFArrayRef?
                var descendant: CGPDFDictionaryRef?
                // Other CMaps can use variable-length codes. Do not interpret
                // their bytes as Identity-H or invent advances for them.
                guard CGPDFDictionaryGetName(font, "Encoding", &encoding), let encoding,
                      String(cString: encoding) == "Identity-H",
                      CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                      CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return nil }
                font = descendant
                codeBytes = 2
                var fallback: CGPDFReal = 1000
                _ = CGPDFDictionaryGetNumber(font, "DW", &fallback)
                defaultWidth = fallback
                widths = [:]
                var entries: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(font, "W", &entries), let entries {
                    var index = 0
                    while index < CGPDFArrayGetCount(entries) {
                        var first: CGPDFInteger = 0
                        guard CGPDFArrayGetInteger(entries, index, &first), (0...65535).contains(first) else { return nil }
                        index += 1
                        var values: CGPDFArrayRef?
                        if CGPDFArrayGetArray(entries, index, &values), let values {
                            for offset in 0..<CGPDFArrayGetCount(values) {
                                var width: CGPDFReal = 0
                                guard first + offset <= 65535, CGPDFArrayGetNumber(values, offset, &width) else { return nil }
                                widths[first + offset] = width
                            }
                            index += 1
                        } else {
                            var last: CGPDFInteger = 0
                            var width: CGPDFReal = 0
                            guard CGPDFArrayGetInteger(entries, index, &last), last >= first, last <= 65535,
                                  CGPDFArrayGetNumber(entries, index + 1, &width) else { return nil }
                            for code in first...last { widths[code] = width }
                            index += 2
                        }
                    }
                }
            } else {
                guard ["Type1", "TrueType", "MMType1"].contains(String(cString: subtype)) else { return nil }
                var first: CGPDFInteger = 0
                var values: CGPDFArrayRef?
                guard CGPDFDictionaryGetInteger(font, "FirstChar", &first),
                      CGPDFDictionaryGetArray(font, "Widths", &values), let values else { return nil }
                codeBytes = 1
                defaultWidth = nil
                widths = [:]
                for offset in 0..<CGPDFArrayGetCount(values) {
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(values, offset, &width) else { return nil }
                    widths[first + offset] = width
                }
            }
        }
    }

    private struct State {
        var transform = CGAffineTransform.identity
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var textPositionKnown = true
        var font: FontWidths?
        var size: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var characterSpace: CGFloat = 0
        var wordSpace: CGFloat = 0
        var leading: CGFloat = 0
        var rise: CGFloat = 0
    }
    private struct Glyph {
        let start: CGPoint
        let end: CGPoint
        let em: CGFloat
    }
    private var state = State()
    private var stack: [State] = []
    private var previous: Glyph?
    private var formDepth = 0
    private var gaps: [CGRect] = []
    private var glyphs: [Glyph] = []
    private var table: CGPDFOperatorTableRef!

    init(page: PDFPage) {
        guard let pageRef = page.pageRef else { return }
        table = CGPDFOperatorTableCreate()
        installCallbacks()
        let stream = CGPDFContentStreamCreateWithPage(pageRef)
        scan(stream)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
    }

    /// PDFKit gives all characters the union box of a line, including tall
    /// radicals/scripts. Match real glyph origins against selected character x
    /// positions to recover the body baseline, not the top of that union box.
    func baseline(in selection: PDFSelection, on page: PDFPage, fontSize: CGFloat, fontTolerance: CGFloat = 0.16) -> CGFloat? {
        let box = selection.bounds(for: page)
        // Do not borrow a baseline below the selected font box. A short
        // formula can share x positions with many glyphs on the next row.
        var minimumY = box.minY - fontSize * 0.1
        var maximumY = box.height > fontSize * 4 && box.width > fontSize * 4
            ? box.minY + fontSize * 0.6 : box.maxY
        if let value = selection.attributedString {
            var hasDropCap = false
            value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, _, _ in
                if let font = font as? NSFont, font.pointSize > fontSize * 1.5 { hasDropCap = true }
            }
            // A drop cap extends down into later rows. Their glyph positions
            // must not win the baseline vote for the opening line.
            if hasDropCap {
                minimumY = max(minimumY, box.maxY - fontSize * 1.2)
                maximumY = box.maxY
            }
        }
        let candidates = glyphs.filter {
            abs($0.em - fontSize) < fontSize * fontTolerance && $0.end.x > $0.start.x
                && abs($0.end.y - $0.start.y) < 0.01
                && $0.start.y >= minimumY && $0.start.y <= maximumY
                && $0.start.x >= box.minX - 0.1 && $0.start.x < box.maxX
        }
        guard !candidates.isEmpty else { return nil }
        let precision = max(0.05, fontSize * 0.025)
        let positions = characterOrigins(in: selection, on: page, precision: precision)
        var votes: [Int: (y: CGFloat, count: Int)] = [:]
        for glyph in candidates {
            let x = Int((glyph.start.x / precision).rounded())
            guard positions.contains(x) || positions.contains(x - 1) || positions.contains(x + 1) else { continue }
            let y = Int((glyph.start.y / precision).rounded())
            let existing = votes[y] ?? (glyph.start.y, 0)
            votes[y] = (existing.y, existing.count + 1)
        }
        return votes.values.max { $0.count == $1.count ? $0.y < $1.y : $0.count < $1.count }?.y
    }

    private func characterOrigins(in selection: PDFSelection, on page: PDFPage, precision: CGFloat) -> Set<Int> {
        var positions = Set<Int>()
        for index in 0..<selection.numberOfTextRanges(on: page) {
            let range = selection.range(at: index, on: page)
            for character in range.location..<NSMaxRange(range) {
                if let rect = page.selection(for: NSRange(location: character, length: 1))?.bounds(for: page) {
                    positions.insert(Int((rect.minX / precision).rounded()))
                }
            }
        }
        return positions
    }

    /// Some malformed PDF font boxes make one period span half a page. Recover
    /// that line's extent from its actual drawing commands instead.
    func positionedBounds(in selection: PDFSelection, on page: PDFPage, fontSize: CGFloat, baseline: CGFloat) -> CGRect? {
        let precision = max(0.05, fontSize * 0.025)
        let positions = characterOrigins(in: selection, on: page, precision: precision)
        let matches = glyphs.filter { glyph in
            let x = Int((glyph.start.x / precision).rounded())
            return abs(glyph.start.y - baseline) < fontSize * 0.2
                && glyph.end.x > glyph.start.x && abs(glyph.end.y - glyph.start.y) < 0.01
                && (positions.contains(x) || positions.contains(x - 1) || positions.contains(x + 1))
        }
        guard let left = matches.map(\.start.x).min(), let right = matches.map(\.end.x).max() else { return nil }
        return CGRect(x: left, y: baseline - fontSize * 0.2, width: right - left, height: fontSize)
    }

    func restoringSpaces(in selection: PDFSelection, on page: PDFPage, fontSize: CGFloat, baseline: CGFloat?) -> String {
        let original = selection.string ?? ""
        let bounds = selection.bounds(for: page)
        let candidates = gaps.filter { $0.intersects(bounds) }
        guard !candidates.isEmpty || original.contains(where: { Self.accents[$0] != nil }),
              let source = page.string as NSString? else { return original }
        let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
        let extracted = ranges.map { source.substring(with: $0) }.joined()
        // selectionsByLine() omits the final newline from its string while
        // retaining it in the page range.
        guard extracted.trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines) else { return original }
        var result = ""
        for range in ranges {
            var characters: [(text: String, bounds: CGRect?)] = []
            source.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { text, characterRange, _, _ in
                if let text { characters.append((text, page.selection(for: characterRange)?.bounds(for: page))) }
            }
            // TeX can paint an accent separately, then return the text cursor to
            // its base letter. PDFKit may insert a space between these overlapping
            // glyphs. Compose only a geometrically overlapping letter, never a
            // punctuation mark or an adjacent, non-overlapping word.
            var index = 0
            while index < characters.count {
                let mark = characters[index]
                if mark.text.count == 1, let accent = Self.accents[mark.text.first!], let box = mark.bounds {
                    var next = index + 1
                    while next < characters.count, characters[next].text == " " { next += 1 }
                    if next < characters.count, characters[next].text.count == 1,
                       characters[next].text.first!.isLetter, let base = characters[next].bounds,
                       min(box.maxX, base.maxX) - max(box.minX, base.minX) > min(box.width, base.width) * 0.3,
                       box.intersects(base) {
                        characters[next].text = (characters[next].text + accent).precomposedStringWithCanonicalMapping
                        characters.removeSubrange(index..<next)
                    }
                }
                index += 1
            }
            var previousText: String?
            var previousBounds: CGRect?
            for (text, rect) in characters {
                if let previousText, !previousText.contains(where: \.isWhitespace), !text.contains(where: \.isWhitespace),
                   !",.;:!?)]}".contains(text),
                   let rect, let previousBounds, rect.minX > previousBounds.minX {
                    // Use selection ranges, not characterBounds(at:): PDFKit can
                    // index that method differently around inferred spaces/ligatures.
                    // Multiple Unicode characters in one ligature share a box;
                    // never insert a space inside that glyph.
                    // PDFKit gives every character the union height of a line.
                    // With a drop cap, midY lies on the *next* line and would
                    // match unrelated word gaps there. Use the body's upper band.
                    let boundary = CGPoint(x: rect.minX, y: baseline.map { $0 + fontSize * 0.3 }
                                           ?? (rect.maxY - min(rect.height, fontSize) * 0.5))
                    if candidates.contains(where: { $0.contains(boundary) }) { result += " " }
                }
                result += text
                previousText = text
                previousBounds = rect
            }
        }
        return result.trimmingCharacters(in: .newlines)
    }

    private static let accents: [Character: String] = [
        "´": "\u{0301}", "`": "\u{0300}", "ˆ": "\u{0302}", "^": "\u{0302}",
        "˜": "\u{0303}", "~": "\u{0303}", "¨": "\u{0308}", "ˇ": "\u{030C}",
        "˘": "\u{0306}", "˚": "\u{030A}", "˙": "\u{0307}", "˝": "\u{030B}"
    ]

    private func scan(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        if !CGPDFScannerScan(scanner) { gaps = []; glyphs = [] }
        CGPDFScannerRelease(scanner)
    }

    private func show(_ string: CGPDFStringRef) {
        guard state.textPositionKnown, let font = state.font, let bytes = CGPDFStringGetBytePtr(string) else {
            previous = nil; state.textPositionKnown = false; return
        }
        let count = CGPDFStringGetLength(string)
        guard count % font.codeBytes == 0 else { previous = nil; state.textPositionKnown = false; return }
        for index in stride(from: 0, to: count, by: font.codeBytes) {
            let code = font.codeBytes == 1 ? Int(bytes[index]) : Int(bytes[index]) * 256 + Int(bytes[index + 1])
            guard let width = font.widths[code] ?? font.defaultWidth else {
                previous = nil; state.textPositionKnown = false; return
            }
            let advance = (width * state.size / 1000 + state.characterSpace
                           + (font.codeBytes == 1 && code == 32 ? state.wordSpace : 0)) * state.horizontalScale
            let transform = state.textMatrix.concatenating(state.transform)
            let start = CGPoint(x: 0, y: state.rise).applying(transform)
            let end = CGPoint(x: advance, y: state.rise).applying(transform)
            let em = abs(state.size) * hypot(transform.c, transform.d)
            let glyph = Glyph(start: start, end: end, em: em)
            glyphs.append(glyph)
            // Ignore rotation, vertical writing, and right-to-left text here.
            // Their extraction is retained unchanged rather than reordered.
            if end.x > start.x, abs(end.y - start.y) < 0.01, em > 0,
               let previous,
               (abs(start.y - previous.end.y) < min(em, previous.em) * 0.15
                || (em > previous.em * 1.15 && abs(start.y - previous.end.y) < em * 0.65)) {
                let gap = start.x - previous.end.x
                // TeX word spaces in the reported PDF are 0.246–0.415 em;
                // its positive kerning is 0.028 em. Character tracking is
                // included in advance, so it cannot turn every letter into a word.
                if gap > min(em, previous.em) * 0.15, gap < max(em, previous.em) * 2 {
                    gaps.append(CGRect(x: previous.end.x, y: start.y - em * 0.3, width: gap, height: em * 1.1))
                }
            }
            previous = glyph
            state.textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(state.textMatrix)
        }
    }

    private func handle(_ operation: String, _ scanner: CGPDFScannerRef) {
        func number() -> CGFloat? { var value: CGPDFReal = 0; return CGPDFScannerPopNumber(scanner, &value) ? value : nil }
        func matrix() -> CGAffineTransform? {
            guard let f = number(), let e = number(), let d = number(), let c = number(), let b = number(), let a = number() else { return nil }
            return CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
        }
        func move(_ x: CGFloat, _ y: CGFloat) {
            state.lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(state.lineMatrix)
            state.textMatrix = state.lineMatrix
            state.textPositionKnown = true
        }
        switch operation {
        case "q": stack.append(state)
        case "Q":
            if let saved = stack.popLast() {
                let textMatrix = state.textMatrix, lineMatrix = state.lineMatrix
                let textPositionKnown = state.textPositionKnown
                state = saved
                state.textMatrix = textMatrix; state.lineMatrix = lineMatrix
                state.textPositionKnown = textPositionKnown
            }
        case "cm": if let matrix = matrix() { state.transform = matrix.concatenating(state.transform) }
        case "BT": state.textMatrix = .identity; state.lineMatrix = .identity; state.textPositionKnown = true
        case "ET": break
        case "Tf":
            var name: UnsafePointer<CChar>?
            state.font = nil
            guard let size = number(), CGPDFScannerPopName(scanner, &name), let name else { return }
            state.size = size
            let stream = CGPDFScannerGetContentStream(scanner)
            var dictionary: CGPDFDictionaryRef?
            if let resource = CGPDFContentStreamGetResource(stream, "Font", name),
               CGPDFObjectGetValue(resource, .dictionary, &dictionary), let dictionary { state.font = FontWidths(dictionary) }
        case "Tm":
            if let matrix = matrix() { state.textMatrix = matrix; state.lineMatrix = matrix; state.textPositionKnown = true }
        case "Td", "TD":
            if let y = number(), let x = number() { if operation == "TD" { state.leading = -y }; move(x, y) }
        case "T*": move(0, -state.leading)
        case "TL": if let value = number() { state.leading = value }
        case "Tc": if let value = number() { state.characterSpace = value }
        case "Tw": if let value = number() { state.wordSpace = value }
        case "Tz": if let value = number() { state.horizontalScale = value / 100 }
        case "Ts": if let value = number() { state.rise = value }
        case "Tj", "'", "\"":
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            if operation == "\"", let characterSpace = number(), let wordSpace = number() {
                state.characterSpace = characterSpace; state.wordSpace = wordSpace
            }
            if operation != "Tj" { move(0, -state.leading) }
            show(string)
        case "TJ":
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var adjustment: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string { show(string) }
                else if CGPDFArrayGetNumber(array, index, &adjustment) {
                    let shift = -adjustment * state.size * state.horizontalScale / 1000
                    state.textMatrix = CGAffineTransform(translationX: shift, y: 0).concatenating(state.textMatrix)
                }
            }
        case "Do":
            var name: UnsafePointer<CChar>?
            let stream = CGPDFScannerGetContentStream(scanner)
            var form: CGPDFStreamRef?
            guard formDepth < 16, CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(stream, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &form), let form else { return }
            guard let dictionary = CGPDFStreamGetDictionary(form) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
            let saved = state
            let savedStack = stack
            stack = []
            var values: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &values), let values, CGPDFArrayGetCount(values) == 6 {
                var numbers = [CGFloat](repeating: 0, count: 6)
                for index in 0..<6 { _ = CGPDFArrayGetNumber(values, index, &numbers[index]) }
                state.transform = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5]).concatenating(state.transform)
            }
            formDepth += 1
            previous = nil
            let child = CGPDFContentStreamCreateWithStream(form, resources, stream)
            scan(child)
            CGPDFContentStreamRelease(child)
            formDepth -= 1
            state = saved; stack = savedStack; previous = nil
        default: break
        }
    }

    private func installCallbacks() {
        CGPDFOperatorTableSetCallback(table, "q") { s, i in PDFWordSpacing.owner(i).handle("q", s) }
        CGPDFOperatorTableSetCallback(table, "Q") { s, i in PDFWordSpacing.owner(i).handle("Q", s) }
        CGPDFOperatorTableSetCallback(table, "cm") { s, i in PDFWordSpacing.owner(i).handle("cm", s) }
        CGPDFOperatorTableSetCallback(table, "BT") { s, i in PDFWordSpacing.owner(i).handle("BT", s) }
        CGPDFOperatorTableSetCallback(table, "ET") { s, i in PDFWordSpacing.owner(i).handle("ET", s) }
        CGPDFOperatorTableSetCallback(table, "Tf") { s, i in PDFWordSpacing.owner(i).handle("Tf", s) }
        CGPDFOperatorTableSetCallback(table, "Tm") { s, i in PDFWordSpacing.owner(i).handle("Tm", s) }
        CGPDFOperatorTableSetCallback(table, "Td") { s, i in PDFWordSpacing.owner(i).handle("Td", s) }
        CGPDFOperatorTableSetCallback(table, "TD") { s, i in PDFWordSpacing.owner(i).handle("TD", s) }
        CGPDFOperatorTableSetCallback(table, "T*") { s, i in PDFWordSpacing.owner(i).handle("T*", s) }
        CGPDFOperatorTableSetCallback(table, "TL") { s, i in PDFWordSpacing.owner(i).handle("TL", s) }
        CGPDFOperatorTableSetCallback(table, "Tc") { s, i in PDFWordSpacing.owner(i).handle("Tc", s) }
        CGPDFOperatorTableSetCallback(table, "Tw") { s, i in PDFWordSpacing.owner(i).handle("Tw", s) }
        CGPDFOperatorTableSetCallback(table, "Tz") { s, i in PDFWordSpacing.owner(i).handle("Tz", s) }
        CGPDFOperatorTableSetCallback(table, "Ts") { s, i in PDFWordSpacing.owner(i).handle("Ts", s) }
        CGPDFOperatorTableSetCallback(table, "Tj") { s, i in PDFWordSpacing.owner(i).handle("Tj", s) }
        CGPDFOperatorTableSetCallback(table, "TJ") { s, i in PDFWordSpacing.owner(i).handle("TJ", s) }
        CGPDFOperatorTableSetCallback(table, "'") { s, i in PDFWordSpacing.owner(i).handle("'", s) }
        CGPDFOperatorTableSetCallback(table, "\"") { s, i in PDFWordSpacing.owner(i).handle("\"", s) }
        CGPDFOperatorTableSetCallback(table, "Do") { s, i in PDFWordSpacing.owner(i).handle("Do", s) }
    }
    private static func owner(_ info: UnsafeMutableRawPointer?) -> PDFWordSpacing {
        Unmanaged<PDFWordSpacing>.fromOpaque(info!).takeUnretainedValue()
    }
}
