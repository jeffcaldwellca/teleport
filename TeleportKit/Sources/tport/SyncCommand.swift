import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Bring a remote folder up to date with a local one (or the reverse), transferring only what differs.",
        discussion: """
        A file is transferred when it is missing at the destination, its size differs, or the source is newer. \
        Nothing at the destination is deleted unless --delete is given. Use --dry-run to see what would happen.
        """
    )

    enum Direction: String, ExpressibleByArgument, CaseIterable {
        case up, down
    }

    @Argument(help: "Local folder.")
    var local: String

    @Argument(help: "Remote folder as an sftp://, ftp://, or ftps:// URL.")
    var url: String

    @Option(help: "up: make the remote folder match the local one. down: make the local folder match the remote one.")
    var direction: Direction = .up

    @Flag(help: "Delete files and folders that exist only at the destination. Local deletions go to the Trash.")
    var delete = false

    @Flag(help: "Show what would be done without changing anything.")
    var dryRun = false

    @Flag(help: "Compare sizes only, ignoring modification times.")
    var sizeOnly = false

    @Option(help: "Skip paths matching this pattern, on both sides (repeatable). `node_modules` or `*.log` match at any depth; `build/cache` matches from the synced folder. Excluded paths are never deleted.")
    var exclude: [String] = []

    @Flag(help: "With --delete, allow an empty source folder to empty the destination.")
    var allowEmptySource = false

    @Option(help: "Safety cap on the number of items on either side.")
    var maxItems: Int = FolderSync.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    /// Thrown after everything has been attempted when some actions failed.
    struct Incomplete: LocalizedError {
        let failures: Int
        var errorDescription: String? { "\(failures) item\(failures == 1 ? "" : "s") could not be synced." }
    }

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let localRoot = URL(fileURLWithPath: (local as NSString).expandingTildeInPath)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                try await sync(client: client, localRoot: localRoot, remoteRoot: target.path)
            }
        }
    }

    private func sync(client: RemoteClient, localRoot: URL, remoteRoot: String) async throws {
        let syncDirection: SyncDirection = direction == .up ? .upload : .download
        let comparison = try await FolderSync.compare(
            localRoot: localRoot, remoteRoot: remoteRoot, client: client, direction: syncDirection,
            options: SyncOptions(deleteExtraneous: delete, sizeOnly: sizeOnly, excludes: exclude,
                                 allowEmptySource: allowEmptySource),
            limit: maxItems
        )
        let plan = comparison.plan
        let transferVerb = direction == .up ? "upload" : "download"

        for skipped in plan.skips {
            say("skip \(skipped.relativePath) (\(skipped.reason))")
        }
        guard plan.hasChanges else {
            say("Already in sync.")
            return
        }
        if dryRun {
            for action in plan.actions {
                switch action.kind {
                case .createDirectory: say("mkdir \(action.relativePath)")
                case .transfer:        say("\(transferVerb) \(action.relativePath) (\(action.reason))")
                case .delete:          say("delete \(action.relativePath)")
                case .skip:            break
                }
            }
            say("Dry run: \(summary(of: plan, transferVerb: transferVerb)). Nothing was changed.")
            return
        }

        let remoteTimes = Dictionary(comparison.remote.map { ($0.relativePath, $0.modified) }, uniquingKeysWith: { first, _ in first })
        var failures = 0
        /// Decided when the first deletion comes up: true if something
        /// before it failed.
        var deletionsSkipped: Bool?
        func attempt(_ label: String, _ work: () async throws -> Void) async {
            do {
                try await work()
                say(label)
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("failed: \(label): \(error.localizedDescription)\n".utf8))
            }
        }

        // The destination folder itself may not exist yet.
        if direction == .up {
            try? await client.createDirectory(at: remoteRoot)
        } else {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        }

        for action in plan.actions {
            let localURL = localRoot.appending(path: action.relativePath)
            let remotePath = FolderSync.joined(remoteRoot, action.relativePath)
            switch action.kind {
            case .createDirectory:
                await attempt("mkdir \(action.relativePath)") {
                    if direction == .up {
                        try await client.createDirectory(at: remotePath)
                    } else {
                        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                    }
                }
            case .transfer:
                await attempt("\(transferVerb) \(action.relativePath)") {
                    if direction == .up {
                        try await client.upload(from: localURL, remotePath: remotePath, resume: false) { _, _ in }
                        // So the next run sees the pair as in sync, where the server allows it.
                        if let modified = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                            await client.setModifiedDate(modified, at: remotePath)
                        }
                    } else {
                        try await client.download(remotePath: remotePath, to: localURL, resume: false) { _, _ in }
                        var modified = remoteTimes[action.relativePath] ?? nil
                        if modified == nil { modified = await client.remoteModifiedDate(at: remotePath) }
                        if let modified {
                            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: localURL.path)
                        }
                    }
                }
            case .delete:
                // Deletions come last in the plan. If anything before them
                // failed, leave the destination as it is: a renamed file is
                // "transfer the new name, delete the old", and deleting the
                // old after the new failed to arrive would lose it.
                if deletionsSkipped == nil { deletionsSkipped = failures > 0 }
                if deletionsSkipped == true { continue }
                await attempt("delete \(action.relativePath)") {
                    if direction == .up {
                        try await client.delete(at: remotePath, isDirectory: action.isDirectory)
                    } else {
                        try FileManager.default.trashItem(at: localURL, resultingItemURL: nil)
                    }
                }
            case .skip:
                break
            }
        }

        if deletionsSkipped == true {
            FileHandle.standardError.write(Data(
                "Some items failed, so nothing was deleted. Fix them and run the same command again.\n".utf8))
        } else {
            say("Done: \(summary(of: plan, transferVerb: transferVerb)).")
        }
        if failures > 0 { throw Incomplete(failures: failures) }
    }

    private func summary(of plan: SyncPlan, transferVerb: String) -> String {
        var parts = ["\(plan.transfers.count) to \(transferVerb)"]
        if !plan.directories.isEmpty { parts.append("\(plan.directories.count) folder\(plan.directories.count == 1 ? "" : "s") to create") }
        if !plan.deletions.isEmpty { parts.append("\(plan.deletions.count) to delete") }
        if !plan.skips.isEmpty { parts.append("\(plan.skips.count) skipped") }
        return parts.joined(separator: ", ")
    }

    private func say(_ line: String) {
        if !global.quiet { print(line) }
    }
}
