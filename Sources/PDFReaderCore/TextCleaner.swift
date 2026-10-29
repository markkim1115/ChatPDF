import Foundation

/// Joins visual line wraps without removing explicit paragraphs or list items.
public enum TextCleaner {
    public static func clean(_ text: String, isKnownWord: ((String) -> Bool)? = nil,
                             preserveHyphen: ((String) -> Bool)? = nil,
                             preserveListBreaks: Bool = true) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        var result = ""
        var paragraphBreak = false
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                if !result.isEmpty { paragraphBreak = true }
                continue
            }
            if result.isEmpty {
                result = line
            } else if paragraphBreak {
                result += "\n\n" + line
            } else if preserveListBreaks, isListItem(line),
                      !continuesInlineEnumeration(previous: result, current: line),
                      !continuesInlineLetter(previous: result, current: line),
                      !continuesDashClause(previous: result, current: line),
                      !continuesReferencePart(previous: result, current: line),
                      !continuesAuthorInitial(previous: result, current: line) {
                result += "\n" + line
            } else {
                result = join(result, line, isKnownWord: isKnownWord, preserveHyphen: preserveHyphen)
            }
            paragraphBreak = false
        }
        return result.replacingOccurrences(of: "\u{00ad}", with: "")
    }

    private static func join(_ left: String, _ right: String, isKnownWord: ((String) -> Bool)?,
                             preserveHyphen: ((String) -> Bool)?) -> String {
        if left.hasSuffix("\u{00ad}") { return String(left.dropLast()) + right }
        if let match = left.range(of: #"[\p{L}\p{N}]+[-‐]$"#, options: .regularExpression),
           let start = right.range(of: #"^[\p{L}\p{N}]+"#, options: .regularExpression) {
            let prefix = String(left[match].dropLast())
            let suffix = String(right[start])
            // Short fragments such as "of", "ten", "mod" and "els" all pass
            // the macOS spell checker. Their individual validity is not evidence
            // of a compound. Prefer a recognized joined word unless the document
            // itself uses this exact hyphenated form away from a line ending.
            if (suffix.first?.isLowercase == true || (prefix.allSatisfy(\.isUppercase) && suffix.allSatisfy(\.isUppercase))),
               prefix.allSatisfy(\.isLetter),
               preserveHyphen?(prefix + "-" + suffix) != true,
               let isKnownWord, isKnownWord(prefix + suffix) {
                return String(left.dropLast()) + right
            }
            return left + right
        }
        if let last = left.unicodeScalars.last, let first = right.unicodeScalars.first,
           isCJK(last.value) && isCJK(first.value) { return left + right }
        return left + " " + right
    }

    static func isListItem(_ text: String) -> Bool {
        text.range(of: #"^(?:[•◦▪‣●–—*\-]|\(?\d{1,3}[.)]|[a-zA-Z][.)])\s+"#,
                   options: .regularExpression) != nil
    }

    static func continuesAuthorInitial(previous: String, current: String) -> Bool {
        // Bibliographies often wrap immediately after a surname and comma.
        // Its initial ("H. 2015.") is not an alphabetic list marker.
        previous.hasSuffix(",")
            && current.range(of: #"^[A-Z]\.\s+"#, options: .regularExpression) != nil
            && (previous.range(of: #"\b[A-Z]\.(?:\s|;)"#, options: .regularExpression) != nil
                || current.range(of: #"^[A-Z]\.\s+(?:[A-Z]\.\s+)*\d{4}\b"#, options: .regularExpression) != nil)
    }

    static func continuesDashClause(previous: String, current: String) -> Bool {
        current.range(of: #"^[–—\-]\s"#, options: .regularExpression) != nil
            && previous.range(of: #"[.!?:;][\"'”’)]?$"#, options: .regularExpression) == nil
            && !isListItem(String(previous.split(separator: "\n").last ?? ""))
    }

    static func continuesReferencePart(previous: String, current: String) -> Bool {
        previous.range(of: #"\b(?:Part|Volume)$"#, options: .regularExpression) != nil
            && current.range(of: #"^[IVXLCDM]+\.\s"#, options: .regularExpression) != nil
    }

    static func continuesInlineLetter(previous: String, current: String) -> Bool {
        guard current.range(of: #"^[a-z]\.\s"#, options: .regularExpression) != nil else { return false }
        let last = String(previous.split(separator: "\n").last ?? "")
        return !isListItem(last) && previous.range(of: #"[.!?:;][\"'”’)]?$"#, options: .regularExpression) == nil
    }

    static func continuesInlineEnumeration(previous: String, current: String) -> Bool {
        guard let marker = current.range(of: #"^\(\d{1,3}\)\s+"#, options: .regularExpression),
              let number = Int(current[marker].filter(\.isNumber)), number > 1 else { return false }
        // An enumerated clause remains prose even if typesetting puts its next
        // number at the start of a physical line. A real list's prior marker is
        // at a line start, or is outside the selection altogether.
        guard let prior = previous.range(of: "(\(number - 1))", options: .backwards) else { return false }
        let before = previous[..<prior.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return !before.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x9fff).contains(value) || (0x3040...0x30ff).contains(value)
            || (0x20000...0x2fa1f).contains(value)
    }
}
