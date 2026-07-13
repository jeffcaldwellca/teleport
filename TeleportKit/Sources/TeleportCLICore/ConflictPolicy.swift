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
        switch direction {
        case .get:
            if let r = remoteDate, let l = localDate, r > l { return .proceed }
            return .skip
        case .put:
            if let l = localDate, let r = remoteDate, l > r { return .proceed }
            return .skip
        }
    }
}
