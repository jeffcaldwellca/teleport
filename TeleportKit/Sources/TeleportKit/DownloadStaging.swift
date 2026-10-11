import Foundation
import Darwin

/// Downloads are written to a `<name>.part` sibling and renamed over the
/// destination only once complete and verified, so a failed, cancelled or
/// refused transfer never damages a file that was already there.
public enum DownloadStaging {

    /// Where an in-progress download of `destination` is staged.
    public static func partialURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".part")
    }

    /// Remove any staged bytes for `destination` (e.g. after a cancel).
    public static func discardPartial(for destination: URL) {
        try? FileManager.default.removeItem(at: partialURL(for: destination))
    }

    /// Bytes already staged that a resumed transfer can continue from; 0 means
    /// start clean (not resuming, nothing staged, or the staged file isn't
    /// smaller than the source).
    static func resumeOffset(for destination: URL, resume: Bool, total: Int64) -> Int64 {
        guard resume,
              let staged = (try? FileManager.default.attributesOfItem(
                  atPath: partialURL(for: destination).path)[.size]) as? Int64,
              staged > 0, total > 0, staged < total else { return 0 }
        return staged
    }

    /// Open the staging file for writing, refusing to follow symlinks.
    /// Defends against an attacker pre-placing a symlink at a predicted path.
    static func openPartial(for destination: URL, truncate: Bool) throws -> FileHandle {
        var flags: Int32 = O_WRONLY | O_CREAT | O_NOFOLLOW
        if truncate { flags |= O_TRUNC }
        let fd = partialURL(for: destination).path.withCString { path in
            Darwin.open(path, flags, 0o644)
        }
        guard fd >= 0 else {
            let err = errno
            throw RemoteClientError.transferFailed(
                "Could not open destination: \(String(cString: strerror(err)))"
            )
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Atomically move the completed staging file over `destination`.
    static func commit(to destination: URL) throws {
        guard rename(partialURL(for: destination).path, destination.path) == 0 else {
            let err = errno
            throw RemoteClientError.transferFailed(
                "Could not move the finished download into place: \(String(cString: strerror(err)))"
            )
        }
    }

    /// After a failed transfer: keep staged bytes for a later resume, but
    /// don't litter the folder with an empty staging file.
    static func discardEmptyPartial(for destination: URL) {
        let staged = (try? FileManager.default.attributesOfItem(
            atPath: partialURL(for: destination).path)[.size]) as? Int64
        if staged == 0 { discardPartial(for: destination) }
    }
}
