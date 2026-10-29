import AppKit
import PDFKit
import Vision

/// On-device OCR is an explicit fallback; native text remains the normal copy path.
public enum PDFOCR {
    public struct TextLine {
        public let text: String
        /// Vision image coordinates: normalized, with the origin at bottom left.
        public let bounds: CGRect
        public let confidence: Float
    }

    public enum Failure: LocalizedError {
        case cannotCopy, cannotRender, noText
        public var errorDescription: String? {
            switch self {
            case .cannotCopy: return "이 PDF는 텍스트 복사를 허용하지 않습니다."
            case .cannotRender: return "선택한 영역을 이미지로 읽을 수 없습니다."
            case .noText: return "선택한 영역에서 문자를 찾지 못했습니다. 글자가 있는 영역을 다시 선택해 주세요."
            }
        }
    }

    /// Render the same rotated crop-box coordinates displayed by PDFView. Call
    /// on the main thread: PDFKit rendering must not race the document view.
    public static func render(page: PDFPage, region: CGRect) throws -> CGImage {
        guard page.document?.allowsCopying == true else { throw Failure.cannotCopy }
        let crop = page.bounds(for: .cropBox)
        let display = crop.applying(page.transform(for: .cropBox))
        let clipped = region.intersection(display)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw Failure.cannotRender }
        let scale = min(4, 4096 / max(clipped.width, clipped.height))
        guard let context = CGContext(data: nil, width: Int(ceil(clipped.width * scale)),
                                      height: Int(ceil(clipped.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.cannotRender }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -clipped.minX, y: -clipped.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw Failure.cannotRender }
        return image
    }

    /// Run off the main thread. Only pixels enter Vision; the PDF is never sent
    /// to a server and is not modified by recognizing a region.
    public static func recognize(_ image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let languages = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["en-US", "ko-KR"].filter(languages.contains)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TextLine(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
        }
        guard !lines.isEmpty else { throw Failure.noText }
        return lines
    }
}
