import Foundation
import TeleportKit

public enum TportExitCode: Int32 {
    case success          = 0
    case generalFailure   = 1
    case usage            = 2
    case authFailed       = 3
    case notFound          = 4
    case connectionFailed = 5
    case hostKey          = 6

    public static func map(_ error: Error) -> TportExitCode {
        if error is TportUsageError { return .usage }
        if let e = error as? RemoteClientError {
            switch e {
            case .authenticationFailed, .permissionDenied:
                return .authFailed
            case .fileNotFound:
                return .notFound
            case .notConnected, .connectionFailed:
                return .connectionFailed
            case .hostKeyUntrusted, .hostKeyMismatch:
                return .hostKey
            case .transferFailed, .unsupported, .unknown:
                return .generalFailure
            }
        }
        if let e = error as? FTPError {
            switch e {
            case .authFailed, .permissionDenied:
                return .authFailed
            case .connectionFailed:
                return .connectionFailed
            default:
                return .generalFailure
            }
        }
        return .generalFailure
    }
}
