import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A local file URL arriving on a folder row of the local pane (a drag from
/// that same pane, or from Finder). Imported from the raw `public.file-url`
/// bytes rather than via `URL`'s own Transferable conformance, which was
/// never observed to fire for table-row drops.
struct LocalFileDrop: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return LocalFileDrop(url: url)
        }
    }
}
