import AppKit
import PDFKit

/// Geometry for one drag, independent of PDF content-stream reading order.
/// Reused while tracking so page layout is not rebuilt for every mouse move.
enum PDFSelectionRepair {
    private struct Fragment {
        let selection: PDFSelection
        let bounds: CGRect
        let size: CGFloat
    }
    private struct Row {
        var fragments: [Fragment]
        var bounds: CGRect
        var size: CGFloat
    }

    static func selection(on page: PDFPage, from anchor: CGPoint, to extent: CGPoint) -> PDFSelection? {
        Layout(page: page)?.selection(from: anchor, to: extent)
    }

    final class Layout {
        private let page: PDFPage
        private let document: PDFDocument
        private let string: NSString
        private let rows: [Row]
        private var characters: [Int: [(PDFSelection, CGRect)]] = [:]

        init?(page: PDFPage) {
            guard page.rotation == 0, let document = page.document, document.allowsCopying,
                  let string = page.string as NSString?, string.length > 0,
                  let entire = page.selection(for: page.bounds(for: .cropBox)) else { return nil }
            self.page = page
            self.document = document
            self.string = string
            var geometry = PDFTextMetrics.LineGeometry()
            let fragments = entire.selectionsByLine().compactMap { part -> Fragment? in
                guard part.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
                let size = PDFTextMetrics.fontSize(of: part, on: page)
                let bounds = geometry.bounds(of: part, on: page, fontSize: size)
                return Fragment(selection: part, bounds: bounds, size: size)
            }
            let sorted = fragments.sorted { $0.bounds.maxY > $1.bounds.maxY }
            var bands: [[Fragment]] = []
            for fragment in sorted {
                if let first = bands.last?.first,
                   first.bounds.height <= first.size * 3, fragment.bounds.height <= fragment.size * 3,
                   abs(first.bounds.midY - fragment.bounds.midY) < max(first.size, fragment.size) * 0.6,
                   abs(first.bounds.maxY - fragment.bounds.maxY) < max(first.size, fragment.size) * 0.35 {
                    bands[bands.count - 1].append(fragment)
                } else { bands.append([fragment]) }
            }
            var rows: [Row] = []
            for band in bands {
                var row: Row?
                for fragment in band.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                    // Justified sentences can contain wider spaces than the
                    // native line splitter accepts. A neighboring column has
                    // a recurring left edge; an isolated sentence fragment does not.
                    let columnStart = fragments.contains {
                        abs($0.bounds.minX - fragment.bounds.minX) < fragment.size * 0.5
                            && abs($0.bounds.midY - fragment.bounds.midY) > fragment.size * 0.7
                            && abs($0.bounds.midY - fragment.bounds.midY) < fragment.size * 12
                            && abs($0.size - fragment.size) < fragment.size * 0.25
                    }
                    if var current = row, fragment.bounds.minX - current.bounds.maxX < max(current.size, fragment.size) * (columnStart ? 0.65 : 1.5) {
                        current.fragments.append(fragment)
                        current.bounds = current.bounds.union(fragment.bounds)
                        current.size = max(current.size, fragment.size)
                        row = current
                    } else {
                        if let row { rows.append(row) }
                        row = Row(fragments: [fragment], bounds: fragment.bounds, size: fragment.size)
                    }
                }
                if let row { rows.append(row) }
            }
            self.rows = rows
        }

        func contains(_ point: CGPoint) -> Bool { row(at: point) != nil }

        private func row(at point: CGPoint) -> Int? {
            rows.indices.filter { rows[$0].bounds.insetBy(dx: -rows[$0].size * 0.4, dy: -2).contains(point) }
                .min { abs(rows[$0].bounds.midY - point.y) < abs(rows[$1].bounds.midY - point.y) }
        }

        func selection(from anchor: CGPoint, to extent: CGPoint) -> PDFSelection? {
            guard let anchorRow = row(at: anchor), let extentRow = row(at: extent) else {
                return selectionInOneDirection(from: anchor, to: extent)
            }
            let first = rows[anchorRow], last = rows[extentRow]
            // A single visual row may contain separate native selections, such
            // as a running header split between the two sides of the page.
            if abs(first.bounds.midY - last.bounds.midY) < max(first.size, last.size) * 0.35 {
                let left = min(anchor.x, extent.x), right = max(anchor.x, extent.x)
                let selection = PDFSelection(document: document)
                for index in rows.indices where abs(rows[index].bounds.midY - first.bounds.midY) < max(rows[index].size, first.size) * 0.35 {
                    guard rows[index].bounds.maxX >= left, rows[index].bounds.minX <= right else { continue }
                    for (character, box) in glyphs(in: index) where box.midX >= left && box.midX <= right {
                        selection.add(character)
                    }
                }
                return selection
            }
            // A short endpoint fragment can omit another fragment of the same
            // sentence in one direction. Keep both proven column selections.
            // If either endpoint crosses columns or cannot be resolved, retain
            // PDFKit's native fallback instead of returning a partial paragraph.
            let top = first.bounds.midY > last.bounds.midY ? anchor : extent
            let bottom = first.bounds.midY > last.bounds.midY ? extent : anchor
            guard let forward = selectionInOneDirection(from: top, to: bottom),
                  let reverse = selectionInOneDirection(from: bottom, to: top) else { return nil }
            forward.add(reverse)
            return forward
        }

        private func selectionInOneDirection(from anchor: CGPoint, to extent: CGPoint) -> PDFSelection? {
            guard let anchorRow = row(at: anchor) else { return nil }
            let origin = rows[anchorRow]
            // Short final lines and paragraph indents still belong to the same
            // column. Its width comes from the surrounding lines, not endpoints.
            let columnRows = rows.indices.filter {
                abs(rows[$0].bounds.minX - origin.bounds.minX) < max(rows[$0].size, origin.size) * 4
                    && min(rows[$0].bounds.maxX, origin.bounds.maxX) > max(rows[$0].bounds.minX, origin.bounds.minX)
            }
            let column = columnRows.reduce(CGRect.null) { $0.union(rows[$1].bounds) }
            let extentRow: Int
            if let hit = row(at: extent) {
                guard columnRows.contains(hit) else { return nil }
                extentRow = hit
            } else {
                guard extent.x >= column.minX - origin.size, extent.x <= column.maxX + origin.size,
                      let nearest = columnRows.min(by: { abs(rows[$0].bounds.midY - extent.y) < abs(rows[$1].bounds.midY - extent.y) }) else { return nil }
                extentRow = nearest
            }
            let forward = anchorRow == extentRow ? anchor.x <= extent.x : origin.bounds.midY > rows[extentRow].bounds.midY
            let firstIndex = forward ? anchorRow : extentRow, lastIndex = forward ? extentRow : anchorRow
            let first = rows[firstIndex], last = rows[lastIndex]
            let start = forward ? anchor : extent, end = forward ? extent : anchor
            let included = columnRows.filter {
                rows[$0].bounds.midY <= first.bounds.midY + 0.1 && rows[$0].bounds.midY >= last.bounds.midY - 0.1
            }.sorted { rows[$0].bounds.midY > rows[$1].bounds.midY }
            let repaired = PDFSelection(document: document)
            for index in included {
                let box = rows[index].bounds
                let onFirstLine = index == firstIndex || (box.intersects(first.bounds)
                    && abs(box.midY - first.bounds.midY) < first.size * 0.6)
                let onLastLine = index == lastIndex || (box.intersects(last.bounds)
                    && abs(box.midY - last.bounds.midY) < last.size * 0.6)
                if !onFirstLine && !onLastLine {
                    for fragment in rows[index].fragments { repaired.add(fragment.selection) }
                } else {
                    for (character, box) in glyphs(in: index) {
                        if onFirstLine && box.midX < start.x { continue }
                        if onLastLine && box.midX > end.x { continue }
                        repaired.add(character)
                    }
                }
            }
            return repaired
        }

        private func glyphs(in index: Int) -> [(PDFSelection, CGRect)] {
            if let cached = characters[index] { return cached }
            let row = rows[index]
            var result: [(PDFSelection, CGRect)] = []
            for fragment in row.fragments {
                for rangeIndex in 0..<fragment.selection.numberOfTextRanges(on: page) {
                    let range = fragment.selection.range(at: rangeIndex, on: page)
                    string.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { text, range, _, _ in
                        guard let text, !text.contains("\n"), let character = self.page.selection(for: range) else { return }
                        var box = character.bounds(for: self.page)
                        if box.width > row.size * 3 { box.size.width = max(0, row.bounds.maxX - box.minX) }
                        result.append((character, box))
                    }
                }
            }
            characters[index] = result
            return result
        }
    }
}
