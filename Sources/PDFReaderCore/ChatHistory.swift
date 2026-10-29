import CryptoKit
import Foundation

public struct ChatMessage: Codable, Identifiable {
    public var id: String
    public var role: String
    public var text: String
    public init(id: String = UUID().uuidString, role: String, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

public struct ChatHistory: Codable {
    public var threadID: String?
    public var model: String?
    public var messages: [ChatMessage] = []
    public var interrupted = false
    public init() {}

    public static func fileURL(for documentURL: URL, directory: URL) -> URL {
        let path = documentURL.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    public static func load(from url: URL) throws -> ChatHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return ChatHistory() }
        return try JSONDecoder().decode(ChatHistory.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
