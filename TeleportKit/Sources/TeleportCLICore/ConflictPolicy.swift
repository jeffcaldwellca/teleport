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

public func decideConflict(
    policy: ConflictPolicy,
    exists: Bool,
    localDate: Date?,
    remoteDate: Date?,
    direction: TransferDirectionCLI
) -> ConflictDecision {
    guard exists else { return .proceed }
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

private func floorToSecond(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}
