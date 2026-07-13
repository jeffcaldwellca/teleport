import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool = false
    var symlinkTarget: String? = nil
    var size: Int64?
    var modifiedDate: Date?
    var permissions: String?
    var owner: String?
    var group: String?

    /// Path-derived identity — selection survives across directory refreshes,
    /// which a freshly-generated `UUID()` would not.
    var id: String { path }

    var isHidden: Bool { name.hasPrefix(".") }

    var displaySize: String {
        guard !isDirectory, let size = size else { return isDirectory ? "—" : "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var contentType: UTType {
        if isDirectory { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var systemImage: String {
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

    var imageColor: String {
        if isDirectory { return "blue" }
        switch contentType {
        case .image:  return "purple"
        case .movie:  return "red"
        case .audio:  return "pink"
        case .pdf:    return "orange"
        default:      return "gray"
        }
    }

    static func placeholder(name: String, isDirectory: Bool) -> FileItem {
        FileItem(name: name, path: "/\(name)", isDirectory: isDirectory)
    }
}
