import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Internal drag payload identifying a remote file/folder. Lets a drag from
    /// the remote pane be dropped on the local pane and routed through the
    /// transfer queue (progress, conflicts, retries) instead of the ad-hoc
    /// temp-file export used for drags out to Finder.
    static let teleportRemoteItem = UTType(exportedAs: "com.teleport.remote-item")
}

/// Codable stand-in for a remote item used in pane-to-pane drags. Carries no
/// client — the drop target resolves the active session, so a stale drag can't
/// smuggle a dead connection.
struct RemoteFileRef: Codable, Transferable {
    let remotePath: String
    let fileName: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .teleportRemoteItem)
    }
}
