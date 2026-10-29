import AppKit
import PDFKit

public enum PDFTextExtractor {
    private struct Line {
        var text: String
        let page: PDFPage
        var bounds: CGRect
        var selectedBounds: CGRect
        var fontSize: CGFloat
        var explicitParagraph: Bool
    }

    public static func clean(_ selection: PDFSelection) -> String {
        let raw = selection.string ?? ""
        let source = raw as NSString
        var cursor = 0
        var spacing: [ObjectIdentifier: PDFWordSpacing] = [:]
        let lines: [Line] = selection.selectionsByLine().compactMap { selectedLine in
            guard let page = selectedLine.pages.first,
                  let text = selectedLine.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            var explicitParagraph = false
            let match = source.range(of: text, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            if match.location != NSNotFound {
                let gap = source.substring(with: NSRange(location: cursor, length: match.location - cursor))
                explicitParagraph = gap.range(of: #"\n\s*\n"#, options: .regularExpression) != nil
                cursor = NSMaxRange(match)
            }
            // Whole-line geometry keeps partial selections from creating false
            // indentation or short-line paragraph boundaries.
            let fullLine = selectedLine.copy() as! PDFSelection
            fullLine.extendForLineBoundaries()
            let size = PDFTextMetrics.fontSize(of: fullLine, on: page)
            let key = ObjectIdentifier(page)
            if spacing[key] == nil { spacing[key] = PDFWordSpacing(page: page) }
            let baseline = spacing[key]!.baseline(in: fullLine, on: page, fontSize: size)
            let restored = spacing[key]!.restoringSpaces(in: selectedLine, on: page, fontSize: size, baseline: baseline)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var box = fullLine.bounds(for: page)
            var selectedBox = selectedLine.bounds(for: page)
            if box.height > size * 4, box.width > size * 4, let baseline,
               let recovered = spacing[key]!.positionedBounds(in: fullLine, on: page, fontSize: size, baseline: baseline) {
                box = recovered
                selectedBox = spacing[key]!.positionedBounds(in: selectedLine, on: page, fontSize: size, baseline: baseline) ?? selectedBox
            }
            // Remove the downward extension of an embedded drop cap from the
            // line metric. Retain its full horizontal extent for indentation.
            let height = min(box.height, size * 1.2)
            return Line(text: restored, page: page,
                        bounds: baseline.map { CGRect(x: box.minX, y: $0 - size * 0.2, width: box.width, height: size) }
                            ?? CGRect(x: box.minX, y: box.maxY - height, width: box.width, height: height),
                        selectedBounds: selectedBox,
                        fontSize: size, explicitParagraph: explicitParagraph)
        }
        return clean(lines: lines, raw: raw, pageText: selection.pages.compactMap(\.string).joined(separator: "\n"))
    }

    public static func cleanRecognized(_ recognized: [PDFOCR.TextLine], in bounds: CGRect, on page: PDFPage) -> String {
        let heights = recognized.map { $0.bounds.height * bounds.height }.sorted()
        // OCR boxes enclose ink, not font ems: a line without descenders looks
        // smaller. Use a shared body estimate, not a false font-size transition.
        let size = heights.isEmpty ? 1 : heights[heights.count / 2] / 0.75
        let lines = recognized.map { item -> Line in
            let box = CGRect(x: bounds.minX + item.bounds.minX * bounds.width,
                             y: bounds.minY + item.bounds.minY * bounds.height,
                             width: item.bounds.width * bounds.width, height: item.bounds.height * bounds.height)
            return Line(text: item.text, page: page, bounds: box, selectedBounds: box,
                        fontSize: size, explicitParagraph: false)
        }
        let raw = recognized.map(\.text).joined(separator: "\n")
        return clean(lines: lines, raw: raw, pageText: raw)
    }

    private static func clean(lines input: [Line], raw: String, pageText: String) -> String {
        var lines = mergingDropCaps(input)
        lines = mergingLineFragments(lines)
        lines = readingOrder(lines)
        lines = mergingLineFragments(lines)
        lines = removingInterleavedFootnotes(lines)
        func occursOnPage(_ word: String) -> Bool {
            let pattern = #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}])"#
            return pageText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var wordCache: [String: Bool] = [:]
        let knownWord: (String) -> Bool = { word in
            if let cached = wordCache[word] { return cached }
            // Spell checking accepts camel-case identifiers such as ResNetlike
            // by splitting their capitals. That does not make them prose words.
            let spelling = word.dropFirst().contains(where: \.isUppercase) ? word.lowercased() : word
            let range = NSSpellChecker.shared.checkSpelling(of: spelling, startingAt: 0,
                language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            let known = range.location == NSNotFound || occursOnPage(word)
            wordCache[word] = known
            return known
        }
        var compoundCache: [String: Bool] = [:]
        let preserveHyphen: (String) -> Bool = { word in
            if let cached = compoundCache[word] { return cached }
            let present = occursOnPage(word)
            compoundCache[word] = present
            return present
        }
        func cleanParagraph(_ text: String) -> String {
            TextCleaner.clean(text, isKnownWord: knownWord, preserveHyphen: preserveHyphen, preserveListBreaks: false)
        }
        guard !lines.isEmpty else { return TextCleaner.clean(raw, isKnownWord: knownWord) }
        var result = ""
        var paragraph = lines[0].text
        for index in 1..<lines.count {
            let line = lines[index]
            let isList = TextCleaner.isListItem(line.text)
                && !TextCleaner.continuesInlineEnumeration(previous: paragraph, current: line.text)
                && !TextCleaner.continuesInlineLetter(previous: paragraph, current: line.text)
                && !TextCleaner.continuesDashClause(previous: paragraph, current: line.text)
                && !TextCleaner.continuesReferencePart(previous: paragraph, current: line.text)
                && !TextCleaner.continuesAuthorInitial(previous: paragraph, current: line.text)
            if isList || isParagraph(at: index, in: lines) {
                result += cleanParagraph(paragraph) + (isList ? "\n" : "\n\n")
                paragraph = line.text
            } else {
                paragraph += "\n" + line.text
            }
        }
        return result + cleanParagraph(paragraph)
    }

    private static func mergingDropCaps(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines {
            if var cap = result.last, cap.page === line.page,
               cap.text.count == 1, cap.text.first!.isLetter,
               line.text.first?.isLowercase == true, cap.fontSize > line.fontSize * 1.5,
               cap.bounds.intersects(line.bounds.insetBy(dx: -line.fontSize * 0.2, dy: 0)),
               abs(cap.bounds.maxX - line.bounds.minX) < line.fontSize * 0.5 {
                cap.text += line.text
                cap.bounds = CGRect(x: cap.bounds.minX, y: line.bounds.minY,
                                    width: line.bounds.maxX - cap.bounds.minX, height: line.bounds.height)
                cap.fontSize = line.fontSize
                cap.selectedBounds = cap.selectedBounds.union(line.selectedBounds)
                result[result.count - 1] = cap
            } else { result.append(line) }
        }
        return result
    }

    private static func mergingLineFragments(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines {
            // PDFKit can return a citation, superscript, or the right half of
            // a caption as a separate line, sometimes after the following row.
            // Join only adjacent fragments on the same physical row. A column
            // gutter must not turn two columns into a single reading line.
            let match = result.indices.reversed().first { index in
                let other = result[index]
                let size = max(other.fontSize, line.fontSize)
                let left = other.selectedBounds.minX < line.selectedBounds.minX ? other : line
                let right = other.selectedBounds.minX < line.selectedBounds.minX ? line : other
                let gap = right.selectedBounds.minX - left.selectedBounds.maxX
                let trailingScript = right.text.count <= 4 && right.fontSize < left.fontSize * 0.85
                    && left.selectedBounds.intersects(right.selectedBounds)
                    && abs(left.selectedBounds.maxX - right.selectedBounds.minX) < size * 1.5
                return other.page === line.page && line.page.rotation % 180 == 0
                    && ((abs(other.selectedBounds.maxY - line.selectedBounds.maxY) < size * 0.35
                         && gap >= -size * 0.85 && gap < size * 1.5) || trailingScript)
                    // A fraction's numerator may overlap its denominator's
                    // font box. Do not move the denominator ahead of it.
                    && !result[(index + 1)...].contains {
                        $0.page === line.page && $0.selectedBounds.intersects(line.selectedBounds)
                    }
            }
            guard let index = match else { result.append(line); continue }
            let other = result[index]
            var left = other.selectedBounds.minX < line.selectedBounds.minX ? other : line
            let right = other.selectedBounds.minX < line.selectedBounds.minX ? line : other
            let gap = right.selectedBounds.minX - left.selectedBounds.maxX
            let size = max(left.fontSize, right.fontSize)
            let punctuation = right.text.first.map { ",.;:!?)]}".contains($0) } ?? false
            let separator = punctuation || gap < size * 0.12 ? "" : " "
            let weight = CGFloat(left.text.count + right.text.count)
            left.fontSize = (left.fontSize * CGFloat(left.text.count) + right.fontSize * CGFloat(right.text.count)) / weight
            let body = left.text.count >= right.text.count ? left.bounds : right.bounds
            left.text += separator + right.text
            let union = left.bounds.union(right.bounds)
            left.bounds = CGRect(x: union.minX, y: body.minY, width: union.width, height: body.height)
            left.selectedBounds = left.selectedBounds.union(right.selectedBounds)
            result[index] = left
        }
        return result
    }

    /// PDF drawing order is not necessarily reading order. Resolve column
    /// gutters before sorting rows, so a two-column selection stays column-wise.
    private static func readingOrder(_ lines: [Line]) -> [Line] {
        func ordered(_ indices: [Int]) -> [Int] {
            guard indices.count > 1 else { return indices }
            let sizes = indices.map { lines[$0].fontSize }.sorted()
            let size = sizes[sizes.count / 2]
            let horizontal = indices.sorted { lines[$0].selectedBounds.minX < lines[$1].selectedBounds.minX }
            var edge = lines[horizontal[0]].selectedBounds.maxX
            for offset in 1..<horizontal.count {
                let next = lines[horizontal[offset]].selectedBounds
                if next.minX - edge > size * 1.5 {
                    let left = Array(horizontal[..<offset]), right = Array(horizontal[offset...])
                    let l = left.map { lines[$0].selectedBounds }.reduce(CGRect.null) { $0.union($1) }
                    let r = right.map { lines[$0].selectedBounds }.reduce(CGRect.null) { $0.union($1) }
                    if left.count > 1, right.count > 1,
                       min(l.height, r.height) > size * 1.5 {
                        return ordered(left) + ordered(right)
                    }
                }
                edge = max(edge, next.maxX)
            }
            let vertical = indices.sorted {
                let a = lines[$0].selectedBounds, b = lines[$1].selectedBounds
                return a.maxY == b.maxY ? $0 < $1 : a.maxY > b.maxY
            }
            // A spanning heading/caption can hide the gutter. Separate blocks
            // at an actual empty horizontal band, then look for columns again.
            var bottom = lines[vertical[0]].selectedBounds.minY
            var split: Int?, largest: CGFloat = size * 0.5
            for offset in 1..<vertical.count {
                let box = lines[vertical[offset]].selectedBounds
                let gap = bottom - box.maxY
                if gap > largest { largest = gap; split = offset }
                bottom = min(bottom, box.minY)
            }
            if let split { return ordered(Array(vertical[..<split])) + ordered(Array(vertical[split...])) }
            var rows: [[Int]] = []
            var rowBounds = CGRect.null
            for index in vertical {
                if let row = rows.last, let anchor = row.first,
                   (abs(lines[anchor].selectedBounds.maxY - lines[index].selectedBounds.maxY)
                    < max(lines[anchor].fontSize, lines[index].fontSize) * 0.35
                    || min(rowBounds.maxY, lines[index].selectedBounds.maxY)
                        - max(rowBounds.minY, lines[index].selectedBounds.minY)
                        > min(rowBounds.height, lines[index].selectedBounds.height) * 0.1) {
                    rows[rows.count - 1].append(index)
                    rowBounds = rowBounds.union(lines[index].selectedBounds)
                } else { rows.append([index]); rowBounds = lines[index].selectedBounds }
            }
            return rows.flatMap { row in
                let horizontal = row.sorted {
                    let a = lines[$0].selectedBounds.minX, b = lines[$1].selectedBounds.minX
                    return a == b ? $0 < $1 : a < b
                }
                // A numerator/denominator or accent overlaps its base in x.
                // Keep that local native order as a unit, after the text to its
                // left, rather than moving the numerator to the start of a line.
                var groups: [[Int]] = [], edge: CGFloat = -.infinity
                for index in horizontal {
                    let box = lines[index].selectedBounds
                    if box.minX < edge {
                        groups[groups.count - 1].append(index)
                        edge = max(edge, box.maxX)
                    } else { groups.append([index]); edge = box.maxX }
                }
                return groups.flatMap { $0.sorted() }
            }
        }
        var pages: [PDFPage] = []
        for line in lines where !pages.contains(where: { $0 === line.page }) { pages.append(line.page) }
        let indices = pages.flatMap { page -> [Int] in
            let indices = lines.indices.filter { lines[$0].page === page }
            let verticalText = indices.contains {
                lines[$0].selectedBounds.height > lines[$0].fontSize * 3
                    && lines[$0].selectedBounds.width < lines[$0].fontSize * 3
            }
            return page.rotation == 0 && !verticalText ? ordered(indices) : indices
        }
        return indices.enumerated().map { offset, index in
            var line = lines[index]
            // A blank separator in drawing order does not describe new neighbors.
            if offset == 0 || indices[offset - 1] != index - 1 { line.explicitParagraph = false }
            return line
        }
    }

    private static func removingInterleavedFootnotes(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let body = result.last, body.page === line.page,
               line.fontSize < body.fontSize * 0.93,
               line.bounds.maxY < body.bounds.minY,
               line.bounds.maxY < line.page.bounds(for: .cropBox).minY + line.page.bounds(for: .cropBox).height * 0.25,
               abs(line.bounds.minX - body.bounds.minX) < body.fontSize * 3,
               !endsSentence(body.text) {
                var end = index
                while end < lines.count, lines[end].page === body.page,
                      lines[end].fontSize < body.fontSize * 0.93,
                      lines[end].bounds.maxY <= line.bounds.maxY + body.fontSize,
                      abs(lines[end].bounds.minX - body.bounds.minX) < body.fontSize * 3 {
                    end += 1
                }
                // Only discard a smaller footer when body text resumes up in
                // the next column. A footnote selected by itself is preserved.
                if end < lines.count, lines[end].page === body.page,
                   abs(lines[end].fontSize - body.fontSize) < body.fontSize * 0.06,
                   lines[end].bounds.minX > body.bounds.maxX,
                   lines[index..<end].allSatisfy({ $0.bounds.maxX < lines[end].bounds.minX }),
                   lines[end].bounds.minY > body.bounds.maxY,
                   lines[end].text.first?.isLowercase == true {
                    index = end
                    continue
                }
            }
            result.append(line)
            index += 1
        }
        return result
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.range(of: #"[.!?。！？][\"'”’)]?$"#, options: .regularExpression) != nil
    }

    private static func isParagraph(at index: Int, in lines: [Line]) -> Bool {
        let previous = lines[index - 1]
        let current = lines[index]
        if current.explicitParagraph { return true }
        guard previous.page === current.page, current.page.rotation % 180 == 0 else { return false }
        let size = max(previous.fontSize, current.fontSize)
        guard size > 0 else { return false }
        if previous.bounds.minX - current.bounds.minX > size * 0.8,
           current.text.range(of: #"^\[\d+\]\s"#, options: .regularExpression) != nil {
            return true
        }
        let step = previous.bounds.maxY - current.bounds.maxY
        // Inline scripts can overlap horizontally and have smaller fonts. They
        // cannot introduce a paragraph until we actually move to another row.
        guard step > size * 0.65 else { return false }
        let fontRatio = size / max(1, min(previous.fontSize, current.fontSize))
        // Small caps and equations can change the representative font without
        // changing the physical line size. A heading changes both together.
        if fontRatio > 1.22,
           (previous.fontSize > current.fontSize && previous.selectedBounds.height > current.selectedBounds.height * 1.15
            || current.fontSize > previous.fontSize && current.selectedBounds.height > previous.selectedBounds.height * 1.15) {
            return true
        }
        // An upward jump or a new column can still continue the same paragraph.
        guard step > 0, abs(previous.bounds.minX - current.bounds.minX) < size * 4 else { return false }
        let local = Array(lines[max(0, index - 5)..<min(lines.count, index + 5)])
        let steps = zip(local, local.dropFirst()).compactMap { first, second -> CGFloat? in
            let delta = first.bounds.maxY - second.bounds.maxY
            guard first.page === second.page, delta > size * 0.7, delta < size * 2.4,
                  abs(first.fontSize - second.fontSize) < size * 0.15,
                  abs(first.bounds.minX - second.bounds.minX) < size * 2 else { return nil }
            return delta
        }.sorted()
        let typicalStep = steps.isEmpty ? size * 1.2 : steps[(steps.count - 1) / 2]
        if step > max(typicalStep * 1.38, size * 1.55) { return true }
        if endsSentence(previous.text), steps.count >= 3, step > typicalStep * 1.2,
           step - typicalStep > size * 0.2 { return true }
        if endsSentence(previous.text), current.bounds.minX - previous.bounds.minX > size * 0.8 { return true }
        let widths = local.filter {
            $0.page === previous.page && abs($0.bounds.minX - previous.bounds.minX) < size * 1.5
        }.map(\.bounds.width).sorted()
        if endsSentence(previous.text), widths.count >= 3 {
            let fullWidth = widths[widths.count * 3 / 4]
            if previous.bounds.width < fullWidth * 0.76 { return true }
        }
        return false
    }
}
