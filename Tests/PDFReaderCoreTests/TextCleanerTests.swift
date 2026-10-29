import Testing
@testable import PDFReaderCore

@Suite @MainActor
struct TextCleanerTests {
    static let example = """
    As illustrated in Fig. 2 (b), the dual-branch network is
    built upon the UNet architecture, involving an encoder and
    an decoder with respective three Lighten Cross-Attention
    (LCA) modules, and multiple skip connections. Two key
    designs in the network are the dual-branch structure and the
    LCA module. We explain the key intuition behind these
    designs as follows.
    """

    @Test func testUserExampleBecomesOneParagraphWithoutChangingWords() {
        #expect(TextCleaner.clean(Self.example) == Self.example.replacingOccurrences(of: "\n", with: " "))
    }
    @Test func testParagraphsAndDifferentLineEndings() {
        #expect(TextCleaner.clean(" First line\r\n second line.\r\n \r\nNext paragraph\rcontinues.\n") == "First line second line.\n\nNext paragraph continues.")
        #expect(TextCleaner.clean("one\u{2028}two\u{2029}three") == "one two\n\nthree")
    }
    @Test func testListsKeepItemsAndUnwrapTheirContinuationLines() {
        #expect(TextCleaner.clean("Introduction:\n1. First item that\nwraps.\n2. Second item.\n• A bullet\ncontinues.") == "Introduction:\n1. First item that wraps.\n2. Second item.\n• A bullet continues.")
    }
    @Test func testHyphensUseEvidenceAndPreserveCompounds() {
        let dictionary: Set<String> = ["architecture", "dual", "branch", "of", "the", "method", "often", "ten", "models", "mod", "els"]
        let known: (String) -> Bool = { dictionary.contains($0) }
        #expect(TextCleaner.clean("architec-\nture", isKnownWord: known) == "architecture")
        #expect(TextCleaner.clean("dual-\nbranch", isKnownWord: known) == "dual-branch")
        #expect(TextCleaner.clean("state-of-\nthe-art method", isKnownWord: known) == "state-of-the-art method")
        #expect(TextCleaner.clean("NovelXYZ-\nmodule", isKnownWord: known) == "NovelXYZ-module")
        #expect(TextCleaner.clean("value -\n2") == "value - 2")
        #expect(TextCleaner.clean("Escamilla-\nHernandez uses GPT-\n4.") == "Escamilla-Hernandez uses GPT-4.")
        #expect(TextCleaner.clean("architec-\nture") == "architec-ture")
        #expect(TextCleaner.clean("of-\nten mod-\nels", isKnownWord: known) == "often models")
        #expect(TextCleaner.clean("night-\ntime", isKnownWord: { $0 == "nighttime" },
                                  preserveHyphen: { $0 == "night-time" }) == "night-time")
    }
    @Test func testInlineEnumerationIsNotAList() {
        #expect(TextCleaner.clean("Our aims are (1) quality, (2) speed,\n(3) accessibility.") == "Our aims are (1) quality, (2) speed, (3) accessibility.")
        #expect(TextCleaner.clean("Tasks:\n(1) Quality\n(2) Speed") == "Tasks:\n(1) Quality\n(2) Speed")
    }
    @Test func testAuthorYearInitialIsNotAList() {
        #expect(TextCleaner.clean("Nakano, M.; and Perez-Meana,\nH. 2015. A facial recognition method.") == "Nakano, M.; and Perez-Meana, H. 2015. A facial recognition method.")
        #expect(TextCleaner.clean("R. Klette, R. Kozera,\nL. Noakes, and J. Weickert, Eds.") == "R. Klette, R. Kozera, L. Noakes, and J. Weickert, Eds.")
        #expect(TextCleaner.clean("Choices:\nA. First option\nB. Second option") == "Choices:\nA. First option\nB. Second option")
    }
    @Test func testSoftHyphenAndNonbreakingSpace() {
        #expect(TextCleaner.clean("architec\u{00ad}\nture with\u{00a0}soft\u{00ad}hyphens") == "architecture with softhyphens")
    }
    @Test func testCJKAndKoreanSpacing() {
        #expect(TextCleaner.clean("中文段落\n继续阅读") == "中文段落继续阅读")
        #expect(TextCleaner.clean("한국어 문장도\n자연스럽게 연결됩니다.") == "한국어 문장도 자연스럽게 연결됩니다.")
    }
    @Test func testEmptyAndSingleLineInput() {
        #expect(TextCleaner.clean(" \n\n") == "")
        #expect(TextCleaner.clean("  unchanged text.  ") == "unchanged text.")
    }
    @Test func dashClausesAndRomanReferencePartsDoNotBecomeLists() {
        #expect(TextCleaner.clean("an automated tool\n— a single click solution.") == "an automated tool — a single click solution.")
        #expect(TextCleaner.clean("Computer Vision\n– ACCV 2010, Proceedings, Part\nI. Lecture Notes.") == "Computer Vision – ACCV 2010, Proceedings, Part I. Lecture Notes.")
        #expect(TextCleaner.clean("Items:\n– first item\n– second item") == "Items:\n– first item\n– second item")
    }

    @Test func inlineVariablesAndUppercaseHyphenationJoinWithoutChangingLists() {
        #expect(TextCleaner.clean("the bottleneck dimension\nr. We test two designs.") == "the bottleneck dimension r. We test two designs.")
        #expect(TextCleaner.clean("Evaluated on MNLI-\nn. The result improved.") == "Evaluated on MNLI-n. The result improved.")
        #expect(TextCleaner.clean("Items:\na. first item\nb. second item") == "Items:\na. first item\nb. second item")
        #expect(TextCleaner.clean("LARGE LAN-\nGUAGE MODELS", isKnownWord: { $0.lowercased() == "language" }) == "LARGE LANGUAGE MODELS")
    }

}
