import Foundation
import TeleportKit

/// An in-memory remote tree for tests: listings come from `tree`, and every
/// mutating call is recorded (and applied where it matters to later listings).
final class TreeClient: RemoteClient, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: [String: [FileItem]]
    private var _calls: [String] = []
    var failingUploads: Set<String> = []

    /// - Parameter tree: directory path → its entries.
    init(tree: [String: [FileItem]] = [:]) { self.tree = tree }

    var calls: [String] { lock.withLock { _calls } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    static func file(_ path: String, size: Int64 = 100, modified: Date? = nil, symlink: Bool = false) -> FileItem {
        FileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
                 isSymlink: symlink, size: size, modifiedDate: modified)
    }
    static func dir(_ path: String) -> FileItem {
        FileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
    }

    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        try lock.withLock {
            guard let entries = tree[absolutePath] else { throw RemoteClientError.fileNotFound(absolutePath) }
            return entries
        }
    }
    func createDirectory(at absolutePath: String) async throws {
        record("mkdir \(absolutePath)")
        lock.withLock { if tree[absolutePath] == nil { tree[absolutePath] = [] } }
    }
    func delete(at absolutePath: String, isDirectory: Bool) async throws {
        record("\(isDirectory ? "rmdir" : "rm") \(absolutePath)")
    }
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if failingUploads.contains(remotePath) { throw RemoteClientError.transferFailed("scripted") }
        record("upload \(remotePath)")
    }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        record("download \(remotePath)")
        try Data("downloaded".utf8).write(to: localURL)
    }
    func setModifiedDate(_ date: Date, at remotePath: String) async { record("mtime \(remotePath)") }
    /// Exact modification times, as MDTM / stat would report them.
    var preciseTimes: [String: Date] = [:]
    func remoteModifiedDate(at remotePath: String) async -> Date? {
        record("mdtm \(remotePath)")
        return preciseTimes[remotePath]
    }

    func connect() async throws {}
    func disconnect() async {}
    func keepAlive() async {}
    func ping() async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func fileExists(at remotePath: String) async -> Bool { false }
}
