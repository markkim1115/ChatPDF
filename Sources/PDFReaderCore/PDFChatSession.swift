import Foundation

public struct ChatModel {
    public let id: String
    public let name: String
    public let effort: String
    public let isDefault: Bool
}

@MainActor
public final class PDFChatSession {
    public var onChange: (() -> Void)?
    public private(set) var history: ChatHistory
    public private(set) var models: [ChatModel] = []
    public private(set) var status = "ChatGPT에 연결할 준비가 되었습니다"
    public private(set) var isBusy = false
    public private(set) var isConnecting = false
    public private(set) var signedIn = false
    public private(set) var isConnected = false
    private let executable: URL
    private let directory: URL
    private let historyURL: URL
    private let documentName: String
    private var rpc: ChatRPC?
    private var connectTask: Task<Void, Error>?
    private var context: PDFChatContext?
    private var resumed = false
    private var turnID: String?
    private var stopRequested = false
    private var closed = false

    public init(executable: URL, directory: URL, documentURL: URL) {
        self.executable = executable
        self.directory = directory
        self.documentName = documentURL.lastPathComponent
        self.historyURL = ChatHistory.fileURL(for: documentURL, directory: directory.appendingPathComponent("Conversations"))
        do {
            history = try ChatHistory.load(from: historyURL)
            if history.interrupted {
                history.messages.append(ChatMessage(role: "notice", text: "이전 답변이 완료되기 전에 창이 닫혔습니다."))
                history.interrupted = false
            }
        } catch {
            history = ChatHistory()
            status = "저장된 대화를 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    public func selectModel(_ id: String) {
        guard !isBusy, models.contains(where: { $0.id == id }) else { return }
        history.model = id
        save()
        onChange?()
    }

    public func connect() async throws {
        if isConnected { return }
        if let connectTask { return try await connectTask.value }
        guard !closed else { throw CancellationError() }
        isConnecting = true
        status = "ChatGPT 계정에 연결 중…"
        onChange?()
        let task = Task { [self] in
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ChatError("ChatGPT 데스크톱 앱이 필요합니다. 앱을 설치하고 로그인한 뒤 다시 연결해 주세요.")
            }
            try PrivateChatStorage.prepareDirectory(directory)
            let transport = ChatRPC()
            rpc = transport
            transport.onNotification = { [weak self] method, params in self?.notification(method, params) }
            transport.onRequest = { [weak self] method, params in
                guard let self else { throw CancellationError() }
                if method == "item/tool/call" {
                    guard let context = self.context, params["threadId"] as? String == self.history.threadID,
                          let name = params["tool"] as? String,
                          let arguments = params["arguments"] as? [String: Any] else {
                        return ["success": false, "contentItems": [["type": "inputText", "text": "현재 PDF를 사용할 수 없습니다."]]]
                    }
                    self.status = name == "view_pdf_page" ? "페이지 이미지를 확인하는 중…" : "PDF 내용을 읽는 중…"
                    self.onChange?()
                    return await context.call(name, arguments: arguments)
                }
                if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                    return ["decision": "decline"]
                }
                throw ChatError("PDF 읽기 외의 작업은 지원하지 않습니다.")
            }
            transport.onDisconnect = { [weak self] error in
                guard let self, !self.closed else { return }
                self.isConnected = false
                self.resumed = false
                if self.isBusy { self.finish(error: error.localizedDescription) }
                else { self.status = error.localizedDescription; self.onChange?() }
            }
            try await transport.start(executable: executable, directory: directory)
            _ = try await transport.request("initialize", [
                "clientInfo": ["name": "pdf_reader", "title": "ChatPDF", "version": "1.1.9"],
                "capabilities": ["experimentalApi": true]
            ])
            try transport.notify("initialized")
            try await transport.verifyToolRestrictions()
            try await refreshAccount()
            if signedIn, let threadID = history.threadID {
                _ = try await transport.request("thread/name/set", ["threadId": threadID, "name": documentName])
            }
            try Task.checkCancellation()
            isConnected = true
        }
        connectTask = task
        do {
            try await task.value
            connectTask = nil; isConnecting = false
            onChange?()
        } catch {
            rpc?.stop(); rpc = nil
            connectTask = nil; isConnecting = false
            status = error.localizedDescription
            onChange?()
            throw error
        }
    }

    private func refreshAccount() async throws {
        guard let rpc else { throw ChatError("ChatGPT 연결을 시작해 주세요.") }
        let result = try await rpc.request("account/read", ["refreshToken": false])
        signedIn = (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
        guard signedIn else { status = "ChatGPT 계정으로 로그인해 주세요"; return }
        var found: [ChatModel] = [], cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 50, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc.request("model/list", params)
            for model in result["data"] as? [[String: Any]] ?? [] {
                guard let id = model["model"] as? String, let name = model["displayName"] as? String,
                      let effort = model["defaultReasoningEffort"] as? String else { continue }
                // All PDF conversations can include rendered page images.
                guard (model["inputModalities"] as? [String])?.contains("image") == true else { continue }
                found.append(ChatModel(id: id, name: name, effort: effort, isDefault: model["isDefault"] as? Bool == true))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        guard !found.isEmpty else { throw ChatError("이 계정에서 PDF 대화에 사용할 수 있는 모델을 찾지 못했습니다.") }
        models = found
        if !found.contains(where: { $0.id == history.model }) { history.model = (found.first(where: { $0.isDefault }) ?? found[0]).id }
        status = "ChatGPT 계정 연결됨"
    }

    public func loginURL() async throws -> URL {
        try await connect()
        guard let rpc else { throw ChatError("ChatGPT에 연결되어 있지 않습니다.") }
        let result = try await rpc.request("account/login/start", ["type": "chatgpt"])
        guard let value = result["authUrl"] as? String, let url = URL(string: value),
              url.scheme?.lowercased() == "https", case .web = ChatLink(url: url) else {
            throw ChatError("로그인 화면을 열지 못했습니다.")
        }
        status = "브라우저에서 ChatGPT 로그인을 완료해 주세요"
        onChange?()
        return url
    }

    public func send(_ question: String, context: PDFChatContext) async {
        guard !isBusy, !closed else { return }
        isBusy = true; stopRequested = false
        self.context = context
        onChange?()
        do {
            try await connect()
            guard signedIn, let rpc, let model = models.first(where: { $0.id == history.model }) else {
                throw ChatError("ChatGPT 계정으로 로그인한 뒤 질문해 주세요.")
            }
            guard !closed, !stopRequested else { throw CancellationError() }
            if !resumed {
                status = "PDF 대화를 준비하는 중…"
                onChange?()
                var params: [String: Any] = [
                    "model": model.id, "cwd": directory.path, "approvalPolicy": "never", "sandbox": "read-only",
                    "baseInstructions": PDFChatContext.instructions, "config": rpc.sessionConfiguration
                ]
                if let threadID = history.threadID {
                    params["threadId"] = threadID
                    params["excludeTurns"] = true
                    _ = try await rpc.request("thread/resume", params)
                } else {
                    params["dynamicTools"] = PDFChatContext.tools
                    params["environments"] = [] as [String]
                    params["ephemeral"] = false
                    let result = try await rpc.request("thread/start", params)
                    guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw ChatError("대화를 만들지 못했습니다.") }
                    history.threadID = id
                    save()
                }
                resumed = true
            }
            guard !closed, !stopRequested else { throw CancellationError() }
            // Set the visible name explicitly before the first prompt can become
            // the fallback title. Refresh it on later turns after Save As, too.
            _ = try await rpc.request("thread/name/set", ["threadId": history.threadID!, "name": context.title])
            guard !closed, !stopRequested else { throw CancellationError() }
            history.messages.append(ChatMessage(role: "user", text: question))
            history.interrupted = true
            save()
            status = "답변을 준비하는 중…"
            onChange?()
            let result = try await rpc.request("turn/start", [
                "threadId": history.threadID!, "model": model.id, "effort": model.effort,
                "input": [["type": "text", "text": try context.input(question: question)]],
                "environments": [] as [String], "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
            ])
            if isBusy { turnID = (result["turn"] as? [String: Any])?["id"] as? String }
            if stopRequested { await stop() }
        } catch {
            if !closed { finish(error: error is CancellationError ? "답변을 중지했습니다." : error.localizedDescription) }
        }
    }

    public func stop() async {
        stopRequested = true
        guard let rpc, let threadID = history.threadID, let turnID else { return }
        do {
            _ = try await rpc.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
        } catch { status = error.localizedDescription; onChange?() }
    }

    public func newConversation() throws {
        guard !isBusy else { return }
        if !history.messages.isEmpty {
            let archive = historyURL.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).json")
            try history.save(to: archive)
        }
        let model = history.model
        history = ChatHistory(); history.model = model
        resumed = false
        try history.save(to: historyURL)
        status = signedIn ? "새 대화를 시작하세요" : "ChatGPT 계정으로 로그인해 주세요"
        onChange?()
    }

    public func shutdown() {
        closed = true
        connectTask?.cancel()
        rpc?.stop(); rpc = nil
        context = nil
        save()
        isBusy = false; isConnected = false
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        guard !closed else { return }
        if method == "account/login/completed" {
            if params["success"] as? Bool == true {
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.refreshAccount() }
                    catch { self.status = error.localizedDescription }
                    self.onChange?()
                }
            } else { status = params["error"] as? String ?? "로그인을 완료하지 못했습니다."; onChange?() }
            return
        }
        guard params["threadId"] as? String == history.threadID, isBusy else { return }
        switch method {
        case "turn/started":
            turnID = (params["turn"] as? [String: Any])?["id"] as? String
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            if let index = history.messages.firstIndex(where: { $0.id == id }) { history.messages[index].text += delta }
            else { history.messages.append(ChatMessage(id: id, role: "assistant", text: delta)) }
            status = "답변 중…"
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let id = item["id"] as? String, let text = item["text"] as? String {
                if let index = history.messages.firstIndex(where: { $0.id == id }) { history.messages[index].text = text }
                else { history.messages.append(ChatMessage(id: id, role: "assistant", text: text)) }
                save()
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let state = turn["status"] as? String
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            finish(error: error ?? (state == "interrupted" ? "답변을 중지했습니다." : state == "failed" ? "답변을 완료하지 못했습니다." : nil))
            return
        case "error":
            status = (params["error"] as? [String: Any])?["message"] as? String ?? "연결을 다시 시도하는 중…"
        default: return
        }
        onChange?()
    }

    private func finish(error: String?) {
        isBusy = false; turnID = nil; context = nil
        history.interrupted = false
        if let error { history.messages.append(ChatMessage(role: "notice", text: error)) }
        status = error == nil ? "답변 완료 · 페이지 번호를 누르면 해당 쪽으로 이동합니다" : "다시 질문하거나 새 대화를 시작할 수 있습니다"
        save()
        onChange?()
    }

    private func save() {
        do { try history.save(to: historyURL) }
        catch { status = "대화 저장 실패: \(error.localizedDescription)" }
    }
}
