import Foundation

public enum TransferDirectionCLI {
    case get
    case put
}

public enum ConflictPolicy: String, CaseIterable {
    case overwrite
    case skip
    case ifNewer
}

public enum ConflictDecision {
    case proceed
    case skip
}

/// - Parameter resume: `--resume` was given. The existing destination is
///   then the partial copy to continue, not a file to protect, so the
///   policy (skip by default) doesn't apply to it.
public func decideConflict(
    policy: ConflictPolicy,
    exists: Bool,
    localDate: Date?,
    remoteDate: Date?,
    direction: TransferDirectionCLI,
    resume: Bool = false
) -> ConflictDecision {
    guard exists, !resume else { return .proceed }
    switch policy {
    case .overwrite:
        return .proceed
    case .skip:
        return .skip
    case .ifNewer:
        let (source, dest): (Date?, Date?) = direction == .get ? (remoteDate, localDate) : (localDate, remoteDate)
        // Floor to whole seconds before comparing: FTP's MDTM only reports
        // second-granularity mtimes while local files carry sub-second
        // precision, so a bare `>` would treat an unchanged file as "newer"
        // on every run (10:30:45.732 local vs. 10:30:45.000 remote) and
        // needlessly re-transfer it every time.
        guard let source, let dest, floorToSecond(source) > floorToSecond(dest) else { return .skip }
        return .proceed
    }
}

/// Where a single-file `get` writes: into `local` when it names a folder
/// (an existing one, or written with a trailing slash), as scp and cp do.
public func downloadDestination(remotePath: String, local: String) -> URL {
    let url = URL(fileURLWithPath: local)
    var isDirectory: ObjCBool = false
    let names = local.hasSuffix("/")
        || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    return names ? url.appending(component: (remotePath as NSString).lastPathComponent) : url
}

/// Where a single-file `put` writes: into the remote folder when the URL's
/// path ends in a slash.
public func uploadDestination(localURL: URL, remotePath: String) -> String {
    remotePath.hasSuffix("/") ? remotePath + localURL.lastPathComponent : remotePath
}

private func floorToSecond(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}
