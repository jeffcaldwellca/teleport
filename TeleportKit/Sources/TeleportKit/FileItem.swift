import Foundation
import UniformTypeIdentifiers

public struct FileItem: Identifiable, Hashable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool = false
    public var symlinkTarget: String? = nil
    public var size: Int64?
    public var modifiedDate: Date?
    public var permissions: String?
    public var owner: String?
    public var group: String?

    /// Path-derived identity — selection survives across directory refreshes,
    /// which a freshly-generated `UUID()` would not.
    public var id: String { path }

    public var isHidden: Bool { name.hasPrefix(".") }

    public var displaySize: String {
        guard !isDirectory, let size = size else { return isDirectory ? "—" : "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var contentType: UTType {
        if isDirectory { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    public var systemImage: String {
        if isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if isDirectory { return "folder.fill" }
        switch contentType {
        case .image:  return "photo"
        case .movie:  return "film"
        case .audio:  return "music.note"
        case .pdf:    return "doc.richtext"
        case .zip, .gzip: return "archivebox"
        default:
            if name.hasSuffix(".swift") || name.hasSuffix(".py") || name.hasSuffix(".js") ||
               name.hasSuffix(".ts") || name.hasSuffix(".html") || name.hasSuffix(".css") ||
               name.hasSuffix(".go") || name.hasSuffix(".rs") || name.hasSuffix(".sh") {
                return "doc.text"
            }
            return "doc"
        }
    }

    public var imageColor: String {
        if isDirectory { return "blue" }
        switch contentType {
        case .image:  return "purple"
        case .movie:  return "red"
        case .audio:  return "pink"
        case .pdf:    return "orange"
        default:      return "gray"
        }
    }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: String? = nil,
        size: Int64? = nil,
        modifiedDate: Date? = nil,
        permissions: String? = nil,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.size = size
        self.modifiedDate = modifiedDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    public static func placeholder(name: String, isDirectory: Bool) -> FileItem {
        FileItem(name: name, path: "/\(name)", isDirectory: isDirectory)
    }
}

public extension FileItem {
    /// Whether a drag can be dropped *into* this item. Symlinks are excluded:
    /// listings report them with lstat semantics, so a link to a directory is
    /// indistinguishable from a link to a file.
    var isDropTargetFolder: Bool { isDirectory && !isSymlink }

    /// The folder at `row` in `items`, or nil when the row is out of range or
    /// isn't a droppable folder. `row` is a table row index (-1 = no row).
    static func dropFolder(atRow row: Int, in items: [FileItem]) -> FileItem? {
        guard items.indices.contains(row), items[row].isDropTargetFolder else { return nil }
        return items[row]
    }
}
