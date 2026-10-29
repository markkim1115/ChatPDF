import AppKit
import PDFKit
import Testing
@testable import PDFReaderCore

@Suite(.serialized) @MainActor
struct PDFChatTests {
    @Test func pipeFramesSplitUTF8AndMultipleMessages() throws {
        let payload = Data("{\"id\":1,\"result\":{\"text\":\"한글\"}}\n{\"method\":\"ready\"}\n".utf8)
        var buffer = JSONLineBuffer(), messages: [[String: Any]] = []
        for byte in payload { messages += try buffer.append(Data([byte])) }
        #expect(messages.count == 2)
        #expect((messages[0]["result"] as? [String: Any])?["text"] as? String == "한글")
        #expect(messages[1]["method"] as? String == "ready")
    }

    @Test func pagesSearchAndSnapshotUseRealPDF() throws {
        let pdf = PDFIntegrationTests.makePDF([
            [.init(text: "Orchid experiment", y: 720)],
            [.init(text: "Accuracy is 93.7 percent.", y: 720)]
        ])
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 100, width: 30, height: 30), forType: .text, withProperties: nil)
        note.contents = "Unsaved note"
        pdf.page(at: 1)!.addAnnotation(note)
        let context = try PDFChatContext(document: pdf, title: "한글 + test.pdf", currentPage: 2, selection: "Accuracy")
        pdf.removePage(at: 1)
        let pages = context.call("read_pdf_pages", arguments: ["start_page": 1, "end_page": 2])
        let body = text(pages)
        #expect(body.contains("Orchid experiment"))
        #expect(body.contains("93.7 percent"))
        #expect(body.contains("Unsaved note"))
        #expect(text(context.call("search_pdf", arguments: ["query": "ACCURACY"])).contains("PDF 2쪽"))
        let input = try context.input(question: "설명해 줘")
        #expect(input.contains("Accuracy"))
        #expect(input.contains("\"current_page\":2"))
        #expect(input.contains("설명해 줘"))
        #expect(context.call("read_pdf_pages", arguments: ["start_page": 0, "end_page": 2])["success"] as? Bool == false)
        #expect(context.call("view_pdf_page", arguments: ["page": 3])["success"] as? Bool == false)
    }

    @Test func pageToolReturnsActualImage() throws {
        let pdf = PDFIntegrationTests.makePDF([[.init(text: "A rendered page", y: 720)]])
        let context = try PDFChatContext(document: pdf, title: "test", currentPage: 1, selection: "")
        let result = context.call("view_pdf_page", arguments: ["page": 1])
        let items = try #require(result["contentItems"] as? [[String: Any]])
        let url = try #require(items.last?["imageUrl"] as? String)
        let bytes = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let image = try #require(NSBitmapImageRep(data: bytes))
        #expect(image.pixelsWide > 1000)
        #expect(image.pixelsHigh <= 2000)
    }

    @Test func historyRoundTripsAndIsolatesDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ChatHistory.fileURL(for: URL(fileURLWithPath: "/tmp/a.pdf"), directory: directory)
        let second = ChatHistory.fileURL(for: URL(fileURLWithPath: "/tmp/b.pdf"), directory: directory)
        #expect(first != second)
        var history = ChatHistory()
        history.threadID = "thread-123"
        history.model = "model-from-server"
        history.messages = [ChatMessage(role: "user", text: "이 수식을 설명해 줘")]
        history.interrupted = true
        try history.save(to: first)
        let restored = try ChatHistory.load(from: first)
        #expect(restored.threadID == history.threadID)
        #expect(restored.messages.first?.text == history.messages.first?.text)
        #expect(restored.interrupted)
        #expect(try ChatHistory.load(from: second).messages.isEmpty)
    }

    // Opt in explicitly: uses the signed-in ChatGPT account and a synthetic PDF only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDFREADER_LIVE_CHAT_TEST"] == "1"))
    func liveAccountReadsRendersAndResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFReaderChatTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let documentURL = directory.appendingPathComponent("한글 + & 실험.pdf")
        let pdf = PDFIntegrationTests.makePDF([
            [.init(text: "Demo document. See page 2 for the verification code.", y: 720)],
            [.init(text: "Verification code: ORCHID-937", y: 720)]
        ])
        let context = try PDFChatContext(document: pdf, title: documentURL.lastPathComponent, currentPage: 1, selection: "")
        let session = PDFChatSession(executable: executable, directory: directory, documentURL: documentURL)
        var renderedPage = false
        session.onChange = { [weak session] in if session?.status == "페이지 이미지를 확인하는 중…" { renderedPage = true } }
        defer { session.shutdown() }
        try await session.connect()
        #expect(session.signedIn)
        #expect(!session.models.isEmpty)
        await session.send("read_pdf_pages로 2쪽을 읽고 view_pdf_page로 2쪽 이미지를 확인한 다음, 검증 코드를 한 줄로 알려 줘. 페이지 링크를 포함해.", context: context)
        try await waitForAnswer(session)
        let answer = session.history.messages.filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n")
        #expect(answer.contains("ORCHID-937"))
        #expect(answer.contains("pdfreader://page/2"))
        #expect(renderedPage)
        #expect(session.history.messages.filter { $0.role == "notice" }.isEmpty)
        let threadID = try #require(session.history.threadID)
        let observer = ChatRPC()
        defer { observer.stop() }
        try observer.start(executable: executable, directory: directory)
        _ = try await observer.request("initialize", ["clientInfo": ["name": "pdf_reader_test_observer", "version": "1.1.1"]])
        try observer.notify("initialized")
        let created = try await observer.request("thread/read", ["threadId": threadID])
        #expect((created["thread"] as? [String: Any])?["name"] as? String == documentURL.lastPathComponent)
        // Recreate the old generated title and verify opening the conversation repairs it.
        _ = try await observer.request("thread/name/set", ["threadId": threadID, "name": "현재 PDF 정보 (이전 제목)"])
        session.shutdown()
        let resumed = PDFChatSession(executable: executable, directory: directory, documentURL: documentURL)
        defer { resumed.shutdown() }
        #expect(resumed.history.threadID == threadID)
        try await resumed.connect()
        let renamed = try await observer.request("thread/read", ["threadId": threadID])
        #expect((renamed["thread"] as? [String: Any])?["name"] as? String == documentURL.lastPathComponent)
        await resumed.send("내가 직전에 어떤 확인 작업을 요청했는지 한 문장으로 말해 줘.", context: context)
        try await waitForAnswer(resumed)
        #expect(resumed.history.messages.filter { $0.role == "user" }.count == 2)
        #expect(resumed.history.messages.filter { $0.role == "notice" }.isEmpty)
        #expect(resumed.history.messages.last?.role == "assistant")
        let continued = try await observer.request("thread/read", ["threadId": threadID])
        #expect((continued["thread"] as? [String: Any])?["name"] as? String == documentURL.lastPathComponent)
    }

    private func waitForAnswer(_ session: PDFChatSession) async throws {
        let deadline = Date().addingTimeInterval(120)
        while session.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        #expect(!session.isBusy, "ChatGPT answer timed out: \(session.status)")
        if session.isBusy { await session.stop() }
    }

    private func text(_ result: [String: Any]) -> String {
        (result["contentItems"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
}
