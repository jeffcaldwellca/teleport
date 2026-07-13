import Foundation
import TeleportKit

/// Wraps local filesystem operations to give them the same async interface used elsewhere.
final class LocalFileService {

    static let shared = LocalFileService()
    private let fm = FileManager.default

    func listDirectory(at url: URL) throws -> [FileItem] {
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isSymbolicLinkKey, .fileResourceIdentifierKey
            ],
            options: []
        )

        return contents.map { item -> FileItem in
            let vals = try? item.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isSymbolicLinkKey
            ])
            return FileItem(
                name: item.lastPathComponent,
                path: item.path,
                isDirectory: vals?.isDirectory ?? false,
                isSymlink:   vals?.isSymbolicLink ?? false,
                size:        (vals?.fileSize).map(Int64.init),
                modifiedDate: vals?.contentModificationDate
            )
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func createDirectory(at url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func delete(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    func rename(from: URL, to: URL) throws {
        try fm.moveItem(at: from, to: to)
    }

    func move(from: URL, to: URL) throws {
        try fm.moveItem(at: from, to: to)
    }

    func copy(from: URL, to: URL) throws {
        try fm.copyItem(at: from, to: to)
    }

    func exists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    func homeDirectory() -> URL {
        fm.homeDirectoryForCurrentUser
    }

    /// The user's real Downloads folder — covered by the
    /// `files.downloads.read-write` entitlement, so writes land where the
    /// user expects even under the App Sandbox.
    func downloadsDirectory() -> URL {
        fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDirectory()
    }
}
