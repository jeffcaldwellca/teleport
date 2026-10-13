import Foundation
import TeleportKit

/// Wraps local filesystem operations to give them the same async interface used elsewhere.
final class LocalFileService {

    static let shared = LocalFileService()
    private let fm = FileManager.default

    /// Static and self-contained so it can run off the main actor.
    static func listDirectory(at url: URL) throws -> [FileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isSymbolicLinkKey
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

    /// Moves the item to the Trash (recoverable), returning where it landed.
    @discardableResult
    func delete(at url: URL) throws -> URL? {
        var trashed: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
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
}
