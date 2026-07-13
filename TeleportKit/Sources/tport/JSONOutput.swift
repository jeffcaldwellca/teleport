import Foundation
import TeleportKit

enum JSONOutput {
    private struct FileItemDTO: Encodable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
    }

    private static func dto(_ item: FileItem) -> FileItemDTO {
        FileItemDTO(name: item.name, path: item.path, isDirectory: item.isDirectory,
                   size: item.size, modified: item.modifiedDate)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func encode(_ items: [FileItem]) throws -> String {
        let data = try makeEncoder().encode(items.map(dto))
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func encode(_ item: FileItem) throws -> String {
        let data = try makeEncoder().encode(dto(item))
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
