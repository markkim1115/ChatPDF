import Foundation

/// Local conversation data is private to the current macOS user.
public enum PrivateChatStorage {
    public static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Also protect directories created by earlier versions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        // The private parent protects the temporary file during the atomic write.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func exportPDF(_ data: Data, directory: URL) throws -> URL {
        try prepareDirectory(directory)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("document.pdf")
        do {
            try write(data, to: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
