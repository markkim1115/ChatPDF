import AppKit
import PDFKit

public struct Highlight {
    public let page: PDFPage
    public let annotation: PDFAnnotation
}

public enum Highlights {
    /// Each physical line gets its own annotation, so multi-column selections do
    /// not paint the whitespace between columns.
    public static func make(for selection: PDFSelection, color: NSColor) -> [Highlight] {
        var geometry = PDFTextMetrics.LineGeometry()
        return selection.selectionsByLine().flatMap { line -> [Highlight] in
            line.pages.compactMap { page in
                let bounds = geometry.bounds(of: line, on: page)
                guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else { return nil }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = color
                annotation.contents = line.string
                annotation.modificationDate = Date()
                return Highlight(page: page, annotation: annotation)
            }
        }
    }

    public static func intersecting(_ selection: PDFSelection) -> [Highlight] {
        var seen = Set<ObjectIdentifier>()
        var geometry = PDFTextMetrics.LineGeometry()
        return selection.selectionsByLine().flatMap { line -> [Highlight] in
            line.pages.flatMap { page -> [Highlight] in
                let rect = geometry.bounds(of: line, on: page)
                return page.annotations.compactMap { annotation in
                    guard annotation.type == "Highlight",
                          regions(of: annotation).contains(where: {
                              let overlap = $0.intersection(rect)
                              return !overlap.isNull && overlap.width > 0
                                  && overlap.height >= min($0.height, rect.height) * 0.5
                                  && abs($0.midY - rect.midY) < min($0.height, rect.height) * 0.5
                          }),
                          seen.insert(ObjectIdentifier(annotation)).inserted else { return nil }
                    return Highlight(page: page, annotation: annotation)
                }
            }
        }
    }

    public static func at(_ point: CGPoint, on page: PDFPage) -> Highlight? {
        // Font ascenders/descenders can make neighboring line boxes overlap.
        // Prefer the line centered at the click; stacking order breaks ties.
        let hits = page.annotations.reversed().compactMap { annotation -> (PDFAnnotation, CGFloat)? in
            guard annotation.type == "Highlight",
                  let distance = regions(of: annotation).filter({ $0.contains(point) })
                    .map({ abs($0.midY - point.y) }).min() else { return nil }
            return (annotation, distance)
        }
        guard let annotation = hits.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        return Highlight(page: page, annotation: annotation)
    }

    /// A saved markup may have several quads with blank space between them.
    /// Its outer bounds alone are not a hit target for clicking or erasing.
    public static func regions(of annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints, points.count >= 4, points.count.isMultiple(of: 4) else {
            return [annotation.bounds]
        }
        return stride(from: 0, to: points.count, by: 4).map { start in
            let quad = points[start..<(start + 4)].map(\.pointValue)
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: annotation.bounds.minX + xs.min()!, y: annotation.bounds.minY + ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
}
