import Foundation
import TeleportKit

public enum FolderWalkError: Error, CustomStringConvertible {
    case tooLarge(limit: Int)
    case unreadable(String)
    case unsafeName(String)

    public var description: String {
        switch self {
        case .tooLarge(let limit):
            return "Folder contains more than \(limit) items. Transfer it in smaller pieces (--max-items)."
        case .unreadable(let name):
            return "Could not read the contents of \(name)."
        case .unsafeName(let name):
            return "'\(name)' contains characters that aren't allowed."
        }
    }
}

public enum FolderWalk {
    public static let defaultLimit = 2000

    /// Symlinks are skipped — following them risks cycles and surprising escapes
    /// from the transferred tree, same rationale as the GUI's folder transfer.
    public static func localTree(
        at folderURL: URL,
        limit: Int = defaultLimit
    ) throws -> (dirs: [String], files: [(local: URL, relative: String)]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw FolderWalkError.unreadable(folderURL.lastPathComponent)
        }

        var dirs: [String] = []
        var files: [(local: URL, relative: String)] = []
        let baseCount = folderURL.standardizedFileURL.pathComponents.count

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let components = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            guard !components.isEmpty,
                  components.allSatisfy({ RemotePath.sanitizedFilename($0) != nil }) else { continue }
            let relative = components.joined(separator: "/")
            if vals?.isDirectory == true {
                dirs.append(relative)
            } else {
                files.append((url, relative))
            }
            if dirs.count + files.count > limit {
                throw FolderWalkError.tooLarge(limit: limit)
            }
        }
        return (dirs, files)
    }
}
