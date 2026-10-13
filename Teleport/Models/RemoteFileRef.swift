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
/// client — only the id of the session it was dragged from, which the drop
/// target looks up among the open sessions. A stale drag can't smuggle a dead
/// connection, and a drop can't land on a different server than its source.
struct RemoteFileRef: Codable, Transferable {
    let remotePath: String
    let fileName: String
    let isDirectory: Bool
    var sessionID: UUID? = nil

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .teleportRemoteItem)
    }
}
