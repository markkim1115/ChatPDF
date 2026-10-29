import Foundation

public struct ChatError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Frame bytes before decoding UTF-8: a pipe read may split a Korean character.
struct JSONLineBuffer {
    private var pending = Data()
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        pending.append(data)
        var messages: [[String: Any]] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if !line.isEmpty {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ChatError("ChatGPT 연결에서 올바르지 않은 응답을 받았습니다.")
                }
                messages.append(message)
            }
        }
        return messages
    }
}

@MainActor
public final class ChatRPC {
    public var onNotification: ((String, [String: Any]) -> Void)?
    public var onRequest: ((String, [String: Any]) async throws -> [String: Any])?
    public var onDisconnect: ((Error) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = JSONLineBuffer()
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    public init() {}

    public func start(executable: URL, directory: URL) throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.currentDirectoryURL = directory
        child.arguments = ["app-server", "--listen", "stdio://",
                           "-c", "features.apps=false", "-c", "features.plugins=false",
                           "-c", "mcp_servers={}"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard !data.isEmpty else { return }
                self?.receive(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.process != nil else { return }
                self?.fail(ChatError("ChatGPT 연결이 종료되었습니다. 다시 연결해 주세요."))
            }
        }
        do { try child.run() }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    public func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                self?.timeouts.removeValue(forKey: id)
                self?.pending.removeValue(forKey: id)?.resume(throwing: ChatError("ChatGPT 연결 응답이 늦어지고 있습니다. 다시 시도해 주세요."))
            }
        }
    }

    public func notify(_ method: String, _ params: [String: Any] = [:]) throws {
        try write(["method": method, "params": params])
    }

    public func stop() {
        let child = process
        process = nil
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil; output = nil
        if child?.isRunning == true { child?.terminate() }
        for timer in timeouts.values { timer.cancel() }
        timeouts.removeAll()
        let requests = pending.values
        pending.removeAll()
        requests.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func write(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw ChatError("ChatGPT에 연결되어 있지 않습니다.") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        do {
            for message in try buffer.append(data) {
                if let method = message["method"] as? String {
                    let params = message["params"] as? [String: Any] ?? [:]
                    if let id = message["id"] {
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                guard let handler = self.onRequest else { throw ChatError("지원하지 않는 요청입니다.") }
                                let result = try await handler(method, params)
                                try self.write(["id": id, "result": result])
                            } catch {
                                try? self.write(["id": id, "error": ["code": -32601, "message": error.localizedDescription]])
                            }
                        }
                    } else { onNotification?(method, params) }
                } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                    timeouts.removeValue(forKey: id)?.cancel()
                    if let error = message["error"] as? [String: Any] {
                        continuation.resume(throwing: ChatError(error["message"] as? String ?? "ChatGPT 요청에 실패했습니다."))
                    } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
                }
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        stop()
        onDisconnect?(error)
    }
}
