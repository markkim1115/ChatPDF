import AppKit
import PDFKit

enum PDFTextMetrics {
    /// Malformed font metrics can extend a line into its neighbors or across
    /// the page. Load PDF positioning data only for lines needing repair.
    struct LineGeometry {
        private var spacing: [ObjectIdentifier: PDFWordSpacing] = [:]

        mutating func bounds(of line: PDFSelection, on page: PDFPage) -> CGRect {
            let box = line.bounds(for: page)
            let size = PDFTextMetrics.fontSize(of: line, on: page)
            guard box.height > size * 2 else { return box }
            // A genuine drop cap has a larger font, unlike a broken font box.
            // Preserve its hit area so the opening body line remains selectable.
            if box.height <= size * 4, let text = line.attributedString {
                var largeFont = false
                var hasScripts = false
                text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let font = value as? NSFont, font.pointSize > size * 1.5 { largeFont = true }
                    if let font = value as? NSFont, font.pointSize < size * 0.8 { hasScripts = true }
                }
                // Fractions and scripts can legitimately span several text
                // heights. Their x positions also occur in neighboring prose.
                if largeFont || hasScripts { return box }
            }
            let key = ObjectIdentifier(page)
            if spacing[key] == nil { spacing[key] = PDFWordSpacing(page: page) }
            guard let baseline = spacing[key]!.baseline(in: line, on: page, fontSize: size, fontTolerance: 0.02),
                  let recovered = spacing[key]!.positionedBounds(in: line, on: page, fontSize: size, baseline: baseline) else { return box }
            return recovered
        }
    }

    /// A drop cap, citation or math symbol must not set the size of a whole line.
    static func fontSize(of selection: PDFSelection, on page: PDFPage) -> CGFloat {
        guard let value = selection.attributedString, value.length > 0 else {
            return selection.bounds(for: page).height
        }
        var sizes: [(CGFloat, Int)] = []
        value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, range, _ in
            if let font = font as? NSFont { sizes.append((font.pointSize, range.length)) }
        }
        let total = sizes.reduce(0) { $0 + $1.1 }
        var count = 0
        for (size, length) in sizes.sorted(by: { $0.0 < $1.0 }) {
            count += length
            // Small caps use a smaller font for most letters, with full-sized
            // capitals and punctuation. They still have the body's line size.
            if count * 4 >= total * 3 { return size }
        }
        return selection.bounds(for: page).height
    }
}
