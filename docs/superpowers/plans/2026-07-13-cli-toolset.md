# Teleport CLI toolset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tport`, a stateless CLI exposing full remote file management (ls/stat/get/put/mkdir/rm/mv/chmod/chown/test) over FTP/FTPS/SFTP, sharing protocol code with the GUI app via a new `TeleportKit` Swift package.

**Architecture:** Extract `RemoteClient`/`FTPClient`/`SFTPClient`/`SSHHostKeyStore`/`Connection`/`FileItem`/`RemotePath` into a local SwiftPM package (`TeleportKit/`). The GUI app depends on it unchanged in behavior. A second library target in the same package, `TeleportCLICore`, holds CLI-only pure logic (URL parsing, exit-code mapping, conflict policy, folder walking) with no ArgumentParser dependency, so it's independently `swift test`-able. A thin `tport` executable target (SwiftPM, built via `swift build`, not an Xcode target) wires `TeleportCLICore` + `TeleportKit` to `swift-argument-parser` subcommands.

**Tech Stack:** Swift 5.9, SwiftPM local package, Citadel (SSH/SFTP), swift-argument-parser, XCTest (package tests + existing Xcode `TeleportTests` bundle for docker-backed integration tests).

## Global Constraints

- Full spec: `docs/superpowers/specs/2026-07-13-cli-toolset-design.md`. Every task below implements one section of it.
- CLI binary name is `tport` (not `teleport` — collides with Gravitational Teleport's `teleport`/`tsh`).
- CLI is stateless: no dependency on `ConnectionStore`/Keychain. Auth via `--password` / `TELEPORT_PASSWORD` / `--password-stdin` / `--identity`.
- Host keys fail closed by default; `--accept-new-hostkey` trusts on first use; a changed key always hard-fails (no override).
- v1 recursive transfers are sequential (one file at a time) — no new concurrency work; this is what the committed spec calls for.
- Docker-based integration tests (existing `TransferIntegrationTests.swift` pattern) are to be **written, not run**, per explicit instruction to reach completion without that verification pass. Say so plainly when reporting status — do not claim protocol-level behavior is verified.
- `xcodegen generate` must be re-run (via `scripts/build-release.sh` or directly) after every `project.yml` change before building the Xcode app.

---

### Task 1: Scaffold the TeleportKit package and move pure models

**Files:**
- Create: `TeleportKit/Package.swift`
- Create: `TeleportKit/Sources/TeleportKit/Connection.swift` (moved from `Teleport/Models/Connection.swift`)
- Create: `TeleportKit/Sources/TeleportKit/FileItem.swift` (moved from `Teleport/Models/FileItem.swift`)
- Create: `TeleportKit/Sources/TeleportKit/RemotePath.swift` (moved from `Teleport/Services/RemotePath.swift`)
- Delete: `Teleport/Models/Connection.swift`, `Teleport/Models/FileItem.swift`, `Teleport/Services/RemotePath.swift`

**Interfaces:**
- Produces: `public struct Connection` (all fields/computed props public, explicit `public init` matching the current signature), `public struct FileItem` (all fields public, explicit `public init` matching current signature, `public static func placeholder`), `public enum RemotePath` (`public static func validateCommand`, `sanitizedFilename`, `isContained`), `public enum RemotePathError`.

- [ ] **Step 1: Create the package manifest**

```swift
// TeleportKit/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TeleportKit", dependencies: []),
    ]
)
```

- [ ] **Step 2: Move `Connection.swift`, `FileItem.swift`, `RemotePath.swift` into `TeleportKit/Sources/TeleportKit/`**, marking every currently-`internal` type, stored property, computed property, static function, and initializer `public`. `Connection` and `FileItem` don't have explicit memberwise inits with public visibility today, but both already declare a custom `init(...)` — just prefix it `public init`. Delete the three originals from `Teleport/Models`/`Teleport/Services`.

- [ ] **Step 3: Verify the package builds standalone**

Run: `cd TeleportKit && swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/jeffcaldwell/Development/Teleport
git add TeleportKit Teleport/Models/Connection.swift Teleport/Models/FileItem.swift Teleport/Services/RemotePath.swift
git commit -m "Scaffold TeleportKit package, move Connection/FileItem/RemotePath"
```

(The app target won't compile again until Task 4 wires `project.yml` — that's expected and fine at this checkpoint; the package itself is the testable unit here.)

---

### Task 2: Move RemoteClient protocol, errors, and FTPClient into TeleportKit

**Files:**
- Create: `TeleportKit/Sources/TeleportKit/RemoteClient.swift` (moved from `Teleport/Services/RemoteClient.swift`, `RemoteClientFactory` dropped — see below)
- Create: `TeleportKit/Sources/TeleportKit/FTPClient.swift` (moved from `Teleport/Services/FTPClient.swift`)
- Delete: `Teleport/Services/RemoteClient.swift`, `Teleport/Services/FTPClient.swift`

**Interfaces:**
- Consumes: `Connection`, `FileItem`, `RemotePath` (Task 1).
- Produces: `public protocol RemoteClient: AnyObject, Sendable` (all requirements public by inheritance from the public protocol — no per-method modifier needed), `public enum RemoteClientError: LocalizedError` with the two new cases below, `public actor FTPClient: RemoteClient` (unchanged internals, `public init(connection:password:)`, all protocol-conformance methods `public func`), `public enum FTPListingParser`.

- [ ] **Step 1: Move `RemoteClient.swift`**, marking `RemoteClient` and `RemoteClientError` `public` (cases don't need individual modifiers). **Drop `RemoteClientFactory` entirely** — GUI and CLI each get their own trivial local factory in later tasks, since the right defaults differ per consumer and forcing one shared signature makes FTP callers pass unused SFTP-only parameters. Add two cases to `RemoteClientError`:

```swift
public enum RemoteClientError: LocalizedError {
    case notConnected
    case authenticationFailed
    case permissionDenied
    case fileNotFound(String)
    case transferFailed(String)
    case unsupported(String)
    case hostKeyUntrusted(host: String, port: Int, fingerprint: String)
    case hostKeyMismatch(host: String, port: Int, expected: String, actual: String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:           return "Not connected"
        case .authenticationFailed:   return "Authentication failed"
        case .permissionDenied:       return "Permission denied"
        case .fileNotFound(let p):    return "File not found: \(p)"
        case .transferFailed(let m):  return "Transfer failed: \(m)"
        case .unsupported(let op):    return "\(op) is not supported by this server"
        case .hostKeyUntrusted(let host, let port, let fp):
            return "Host key for \(host):\(port) was not trusted (fingerprint \(fp))"
        case .hostKeyMismatch(let host, let port, let expected, let actual):
            return "Host key for \(host):\(port) has changed — possible MITM attack. " +
                   "Expected \(expected), saw \(actual)."
        case .unknown(let m):         return m
        }
    }
}
```

- [ ] **Step 2: Move `FTPClient.swift`** unchanged apart from adding `public` to the type declaration, `public init(connection:password:)`, and every protocol-conformance method (`connect`, `disconnect`, `listDirectory`, `download`, `upload`, `keepAlive`, `createDirectory`, `delete`, `rename`, `setPermissions`, `setOwnership`, `remoteModifiedDate`, `setModifiedDate`, `fileExists`). `FTPError` and `FTPListingParser` become `public enum`. Internal helpers (`FTPSocket`, `sendCommand`, etc.) stay non-public — nothing outside the file touches them today.

- [ ] **Step 3: Verify**

Run: `cd TeleportKit && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add TeleportKit Teleport/Services/RemoteClient.swift Teleport/Services/FTPClient.swift
git commit -m "Move RemoteClient protocol and FTPClient into TeleportKit"
```

---

### Task 3: Move SSHHostKeyStore and SFTPClient, make host-key trust and key reading injectable

**Files:**
- Create: `TeleportKit/Sources/TeleportKit/SSHHostKeyStore.swift` (moved + refactored)
- Create: `TeleportKit/Sources/TeleportKit/SFTPClient.swift` (moved + refactored)
- Modify: `TeleportKit/Package.swift` (add Citadel dependency)
- Delete: `Teleport/Services/SSHHostKeyStore.swift`, `Teleport/Services/SFTPClient.swift`

**Interfaces:**
- Consumes: `Connection`, `FileItem`, `RemotePath`, `RemoteClient`, `RemoteClientError` (Tasks 1–2).
- Produces:
  - `public actor SSHHostKeyStore` with `public init(storeURL: URL?)`, `public static let shared` (unchanged Application Support path), `public func fingerprint(for:port:) -> String?`, `public func record(host:port:fingerprint:) throws`, `public func forget(host:port:) throws`, `public func forget(id:) throws`, `public func forgetAll() throws`, `public struct TrustedHost`, `public func trustedHosts() -> [TrustedHost]`.
  - `public actor SFTPClient: RemoteClient` with
    `public init(connection: Connection, password: String, hostKeyStore: SSHHostKeyStore = .shared, keyReader: @escaping @Sendable (URL) async throws -> Data = { url in try Data(contentsOf: url) }, onUnknownHostKey: @escaping @Sendable (String, Int, String) async -> Bool = { _, _, _ in false })`.
  - `public enum SSHKeyFingerprint`, `public final class CapturingHostKeyValidator`, `public struct HostKeyMismatchError`.

- [ ] **Step 1: Add Citadel to the package manifest**

```swift
// TeleportKit/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.8.0"),
    ],
    targets: [
        .target(name: "TeleportKit", dependencies: ["Citadel"]),
    ]
)
```

- [ ] **Step 2: Move `SSHHostKeyStore.swift`**, converting it from a hardcoded-path singleton to an instance configured with a `storeURL`. Rename the old static computed `storeURL` to `defaultAppSupportURL` to free up the name for the instance property:

```swift
public actor SSHHostKeyStore {

    public static let shared = SSHHostKeyStore(storeURL: defaultAppSupportURL)

    private struct Entry: Codable {
        var fingerprint: String
        var firstSeen: Date
    }

    private struct File: Codable {
        var schemaVersion: Int = 1
        var entries: [String: Entry] = [:]
    }

    private let storeURL: URL?
    private var file: File?
    private var loaded = false

    public init(storeURL: URL?) {
        self.storeURL = storeURL
    }

    public func fingerprint(for host: String, port: Int) -> String? {
        ensureLoaded()
        return file?.entries[Self.key(host: host, port: port)]?.fingerprint
    }

    public func record(host: String, port: Int, fingerprint: String) throws {
        ensureLoaded()
        if file == nil { file = File() }
        file?.entries[Self.key(host: host, port: port)] = Entry(
            fingerprint: fingerprint, firstSeen: Date()
        )
        try persist()
    }

    public func forget(host: String, port: Int) throws {
        ensureLoaded()
        file?.entries.removeValue(forKey: Self.key(host: host, port: port))
        try persist()
    }

    public func forget(id: String) throws {
        ensureLoaded()
        file?.entries.removeValue(forKey: id)
        try persist()
    }

    public func forgetAll() throws {
        ensureLoaded()
        file?.entries.removeAll()
        try persist()
    }

    public struct TrustedHost: Identifiable, Sendable {
        public let id: String
        public let host: String
        public let port: Int
        public let fingerprint: String
        public let firstSeen: Date
    }

    public func trustedHosts() -> [TrustedHost] {
        ensureLoaded()
        let entries = file?.entries ?? [:]
        return entries.map { key, entry in
            if let colon = key.lastIndex(of: ":"), let port = Int(key[key.index(after: colon)...]) {
                return TrustedHost(id: key, host: String(key[..<colon]), port: port,
                                   fingerprint: entry.fingerprint, firstSeen: entry.firstSeen)
            }
            return TrustedHost(id: key, host: key, port: 0,
                               fingerprint: entry.fingerprint, firstSeen: entry.firstSeen)
        }
        .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    private static func key(host: String, port: Int) -> String { "\(host):\(port)" }

    private static var defaultAppSupportURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appending(component: "Teleport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(component: "known_hosts.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURL, let data = try? Data(contentsOf: url) else {
            file = File()
            return
        }
        file = (try? JSONDecoder().decode(File.self, from: data)) ?? File()
    }

    private func persist() throws {
        guard let file = file, let url = storeURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: [.atomic])
    }
}
```

Also move `SSHKeyFingerprint`, `CapturingHostKeyValidator`, `HostKeyMismatchError` from the same original file, adding `public` throughout (`CapturingHostKeyValidator` needs `public init(expected: String? = nil)` and a `public var captured: String?`; `HostKeyMismatchError` needs public `expected`/`actual` and public `errorDescription`).

- [ ] **Step 3: Move `SFTPClient.swift`**, injecting the two GUI-only dependencies instead of reaching for `BookmarkStore`/`HostKeyConfirmation` singletons directly:

```swift
public actor SFTPClient: RemoteClient {

    private let connection: Connection
    private let password: String
    private let hostKeyStore: SSHHostKeyStore
    private let keyReader: @Sendable (URL) async throws -> Data
    private let onUnknownHostKey: @Sendable (String, Int, String) async -> Bool

    private var ssh: SSHClient?
    private var sftp: Citadel.SFTPClient?

    public init(
        connection: Connection,
        password: String,
        hostKeyStore: SSHHostKeyStore = .shared,
        keyReader: @escaping @Sendable (URL) async throws -> Data = { url in try Data(contentsOf: url) },
        onUnknownHostKey: @escaping @Sendable (String, Int, String) async -> Bool = { _, _, _ in false }
    ) {
        self.connection = connection
        self.password = password
        self.hostKeyStore = hostKeyStore
        self.keyReader = keyReader
        self.onUnknownHostKey = onUnknownHostKey
    }

    public func connect() async throws {
        if ssh != nil || sftp != nil { await disconnect() }

        let authMethod: SSHAuthenticationMethod = try await buildAuthMethod()

        let expected = await hostKeyStore.fingerprint(for: connection.host, port: connection.port)
        let validator = CapturingHostKeyValidator(expected: expected)

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: connection.host,
                port: connection.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch let mismatch as HostKeyMismatchError {
            throw RemoteClientError.hostKeyMismatch(
                host: connection.host, port: connection.port,
                expected: mismatch.expected, actual: mismatch.actual
            )
        }
        ssh = client

        if expected == nil, let captured = validator.captured {
            let trusted = await onUnknownHostKey(connection.host, connection.port, captured)
            guard trusted else {
                try? await client.close()
                ssh = nil
                throw RemoteClientError.hostKeyUntrusted(
                    host: connection.host, port: connection.port, fingerprint: captured
                )
            }
            try? await hostKeyStore.record(
                host: connection.host, port: connection.port, fingerprint: captured
            )
        }

        sftp = try await client.openSFTP()
    }

    private func buildAuthMethod() async throws -> SSHAuthenticationMethod {
        let user = connection.username
        guard connection.sshKeyPath.isEmpty else {
            return try await buildKeyAuth(user: user)
        }
        return .passwordBased(username: user, password: password)
    }

    private func buildKeyAuth(user: String) async throws -> SSHAuthenticationMethod {
        let keyURL = URL(fileURLWithPath: (connection.sshKeyPath as NSString).expandingTildeInPath)
        let keyData = try await keyReader(keyURL)

        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw RemoteClientError.unsupported(
                "SSH key at \(keyURL.path) isn't a readable text key file (OpenSSH/PEM)."
            )
        }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyString) {
            return .ed25519(username: user, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyString) {
            return .rsa(username: user, privateKey: key)
        }
        if keyString.contains("ENCRYPTED") || keyString.contains("aes256-ctr") {
            throw RemoteClientError.unsupported(
                "Passphrase-protected SSH keys aren't supported yet. Remove the passphrase " +
                "(`ssh-keygen -p -f \(keyURL.lastPathComponent)`) or use password authentication."
            )
        }
        throw RemoteClientError.unsupported(
            "Unsupported SSH key at \(keyURL.path). Supported formats: unencrypted OpenSSH " +
            "ed25519 or RSA private keys."
        )
    }

    // disconnect / listDirectory / download / upload / keepAlive / fileExists /
    // remoteModifiedDate / setModifiedDate / createDirectory / delete / rename /
    // setPermissions / setOwnership / openForWriting / transferChunkSize carry
    // over unchanged from the original file (no BookmarkStore/HostKeyConfirmation
    // references in any of them) — just add `public` to each protocol-conformance
    // method and to the `SFTPFileAttributes` helper extension's members.
}
```

The GUI's old `readKeyData(at:)` MainActor/BookmarkStore dance is *not* ported into this file — it becomes the app target's `keyReader` closure in Task 4, including its specific "try selecting the key again…" error message.

- [ ] **Step 4: Verify**

Run: `cd TeleportKit && swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add TeleportKit Teleport/Services/SSHHostKeyStore.swift Teleport/Services/SFTPClient.swift
git commit -m "Move SFTPClient/SSHHostKeyStore into TeleportKit, inject host-key trust and key reading"
```

---

### Task 4: Wire the Teleport app target to TeleportKit

**Files:**
- Modify: `project.yml` (drop the root `Citadel` package + the `Teleport`/`TeleportTests` targets' `package: Citadel` dependency; add a local `TeleportKit` package and depend on it from both targets)
- Create: `Teleport/Services/RemoteClientFactory.swift` (new GUI-local factory replacing the one dropped from `RemoteClient.swift` in Task 2)
- Modify: 17 files needing `import TeleportKit` added (see list below)
- Modify: `Teleport/ViewModels/TransferQueueViewModel.swift` — extend the `isFatal` switch with the two new `RemoteClientError` cases

**Interfaces:**
- Consumes: everything produced by Tasks 1–3.
- Produces: `enum RemoteClientFactory { static func make(for: Connection, password: String) -> RemoteClient }` (same name/signature as before, so the four existing call sites — `TransferQueueViewModel.swift:154,247`, `SidebarView.swift:191`, `ConnectionEditorView.swift:227` — need no changes).

- [ ] **Step 1: Update `project.yml`**

```yaml
packages:
  TeleportKit:
    path: TeleportKit

targets:
  Teleport:
    # ...unchanged...
    dependencies:
      - package: TeleportKit
        product: TeleportKit

  TeleportTests:
    # ...unchanged...
    dependencies:
      - target: Teleport
      - package: TeleportKit
        product: TeleportKit
```

Remove the old root-level `Citadel` package block and both targets' `package: Citadel` dependency entries — `TeleportKit`'s own `Package.swift` pulls Citadel transitively, and the app no longer imports `Citadel` directly.

- [ ] **Step 2: Create the GUI-local `RemoteClientFactory`**

```swift
// Teleport/Services/RemoteClientFactory.swift
import Foundation
import TeleportKit

enum RemoteClientFactory {
    static func make(for connection: Connection, password: String) -> RemoteClient {
        switch connection.connectionProtocol {
        case .sftp:
            return SFTPClient(
                connection: connection,
                password: password,
                hostKeyStore: .shared,
                keyReader: { url in
                    if let data = await MainActor.run(body: {
                        try? BookmarkStore.shared.withAccess(
                            name: BookmarkStore.sshKeyName(for: connection.id)
                        ) { try Data(contentsOf: $0) }
                    }) ?? nil {
                        return data
                    }
                    do {
                        return try Data(contentsOf: url)
                    } catch {
                        throw RemoteClientError.unknown(
                            "Could not read SSH key at \(url.path): \(error.localizedDescription). " +
                            "Try selecting the key again from the connection editor so the app can store a sandbox-friendly bookmark."
                        )
                    }
                },
                onUnknownHostKey: { host, port, fingerprint in
                    await HostKeyConfirmation.shared.confirm(host: host, port: port, fingerprint: fingerprint)
                }
            )
        case .ftp, .ftps:
            return FTPClient(connection: connection, password: password)
        }
    }
}
```

- [ ] **Step 3: Add `import TeleportKit`** (after the existing `import Foundation`/`import SwiftUI` lines, alphabetically) to these 17 files:

```
Teleport/Models/TransferTask.swift
Teleport/Services/ConnectionStore.swift
Teleport/Services/HostKeyConfirmation.swift
Teleport/Services/LocalFileService.swift
Teleport/Services/RemoteEditManager.swift
Teleport/TeleportApp.swift
Teleport/ViewModels/AppState.swift
Teleport/ViewModels/BrowserViewModel.swift
Teleport/ViewModels/TransferQueueViewModel.swift
Teleport/Views/Browser/BrowserPaneView.swift
Teleport/Views/Browser/FileRowView.swift
Teleport/Views/ContentView.swift
Teleport/Views/Sheets/ConnectionEditorView.swift
Teleport/Views/Sheets/HostKeyConfirmationSheet.swift
Teleport/Views/Sheets/PermissionsEditorSheet.swift
Teleport/Views/Sidebar/SidebarView.swift
Teleport/Views/Toolbar/MainToolbarContent.swift
```

An unused `import TeleportKit` in a file that turns out not to need it is a harmless warning, not an error — added everywhere up front to avoid a slow fix-one-error-at-a-time loop against a full Xcode build.

- [ ] **Step 4: Extend `TransferQueueViewModel.isFatal`** to treat host-key rejection as non-retryable (retrying after a rejected/mismatched host key can't succeed):

```swift
private func isFatal(_ error: Error) -> Bool {
    if let e = error as? RemoteClientError {
        switch e {
        case .authenticationFailed, .permissionDenied, .hostKeyUntrusted, .hostKeyMismatch:
            return true
        default: return false
        }
    }
    if let e = error as? FTPError {
        switch e {
        case .authFailed, .permissionDenied: return true
        default: return false
        }
    }
    return false
}
```

- [ ] **Step 5: Regenerate the Xcode project and build**

```bash
cd /Users/jeffcaldwell/Development/Teleport
xcodegen generate --quiet
xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" build 2>&1 | tail -60
```

Expected: `** BUILD SUCCEEDED **`. Fix any remaining "cannot find type in scope" errors by checking whether that specific type needs `public` in `TeleportKit` (Tasks 1–3 should have covered all of them, but double check `KeychainService`, `ConnectionStore`, `LocalFileService`, `RemoteEditManager` — these stay app-local and unchanged, just now sit alongside `import TeleportKit`).

- [ ] **Step 6: Commit**

```bash
git add project.yml Teleport Teleport.xcodeproj
git commit -m "Wire Teleport app target to TeleportKit package"
```

---

### Task 5: Update existing tests for the new module boundary

**Files:**
- Modify: `TeleportTests/FileItemTests.swift`, `TeleportTests/RemotePathTests.swift`, `TeleportTests/SSHKeyFingerprintTests.swift` — swap `@testable import Teleport` for `import TeleportKit`
- Modify: `TeleportTests/TransferIntegrationTests.swift` — swap `@testable import Teleport` for `import TeleportKit`; replace the `HostKeyConfirmation`-polling `autoAcceptHostKeys()` helper with passing `onUnknownHostKey: { _, _, _ in true }` directly to `SFTPClient`'s init
- Create: `TeleportTests/SSHHostKeyStoreTests.swift` — no docker needed, pure file I/O; closes a gap against the spec's "known-hosts file read/write" unit-test commitment that Task 6 doesn't cover (it only tests `TeleportCLICore`, not `TeleportKit` itself)

**Interfaces:**
- Consumes: the now-public `TeleportKit` API from Tasks 1–3.

- [ ] **Step 1: Update imports** in `FileItemTests.swift`, `RemotePathTests.swift`, `SSHKeyFingerprintTests.swift`: replace `@testable import Teleport` with `import TeleportKit`. No other changes — every symbol they reference (`FileItem`, `Connection`, `RemotePath`, `RemotePathError`, `SSHKeyFingerprint`) is now `public` in `TeleportKit`.

- [ ] **Step 2: Update `TransferIntegrationTests.swift`.** Replace:

```swift
import XCTest
import CryptoKit
@testable import Teleport
```
with:
```swift
import XCTest
import CryptoKit
import TeleportKit
```

Delete the `autoAcceptHostKeys()` helper entirely (it drove `HostKeyConfirmation.shared`, which the test no longer touches). Wherever the test constructs an `SFTPClient` for a first-time connection, pass `onUnknownHostKey: { _, _, _ in true }` explicitly:

```swift
let client = SFTPClient(
    connection: sftpConnection(),
    password: Self.password,
    hostKeyStore: SSHHostKeyStore(storeURL: nil),   // in-memory only — never trust across test runs
    onUnknownHostKey: { _, _, _ in true }
)
```

(`storeURL: nil` reuses the existing "no persistence" branch in `ensureLoaded`/`persist` — each test run starts with a clean trust state, which is what "auto-accept" was simulating before.) Remove any remaining call to `autoAcceptHostKeys()` (previously started before a connect and cancelled after — both lines go away).

- [ ] **Step 3: Write `SSHHostKeyStoreTests.swift`**

```swift
import XCTest
import TeleportKit

final class SSHHostKeyStoreTests: XCTestCase {

    private func makeStore() -> (SSHHostKeyStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "known-hosts-test-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SSHHostKeyStore(storeURL: url), url)
    }

    func test_record_thenFingerprint_roundTrips() async throws {
        let (store, _) = makeStore()
        XCTAssertNil(await store.fingerprint(for: "example.com", port: 22))
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")
        let fp = await store.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
    }

    func test_record_persistsAcrossInstances() async throws {
        let (store, url) = makeStore()
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")

        let reopened = SSHHostKeyStore(storeURL: url)
        let fp = await reopened.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
    }

    func test_forget_removesOnlyThatHost() async throws {
        let (store, _) = makeStore()
        try await store.record(host: "a.example.com", port: 22, fingerprint: "SHA256:a")
        try await store.record(host: "b.example.com", port: 22, fingerprint: "SHA256:b")
        try await store.forget(host: "a.example.com", port: 22)
        let a = await store.fingerprint(for: "a.example.com", port: 22)
        let b = await store.fingerprint(for: "b.example.com", port: 22)
        XCTAssertNil(a)
        XCTAssertEqual(b, "SHA256:b")
    }

    func test_nilStoreURL_neverPersists() async throws {
        let store = SSHHostKeyStore(storeURL: nil)
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")
        // Still readable within the same instance (in-memory)...
        let fp = await store.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
        // ...but a fresh instance with the same nil URL starts empty.
        let fresh = SSHHostKeyStore(storeURL: nil)
        let freshFp = await fresh.fingerprint(for: "example.com", port: 22)
        XCTAssertNil(freshFp)
    }
}
```

- [ ] **Step 4: Verify the app scheme still builds its test bundle**

Run: `xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" build-for-testing 2>&1 | tail -40`
Expected: `** TEST BUILD SUCCEEDED **`. This compiles the tests without running the docker-dependent ones (those `XCTSkip` unless `TELEPORT_IT=1`).

- [ ] **Step 5: Run the non-docker tests**

Run: `xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" test -only-testing:TeleportTests/FileItemTests -only-testing:TeleportTests/ConnectionEqualityTests -only-testing:TeleportTests/RemotePathTests -only-testing:TeleportTests/SSHKeyFingerprintTests -only-testing:TeleportTests/SSHHostKeyStoreTests 2>&1 | tail -60`
Expected: `** TEST SUCCEEDED **`, all listed suites pass. (`TransferIntegrationTests` and the CLI integration tests from Task 10 are docker-gated and intentionally excluded here — see the Global Constraints note on verification scope.)

- [ ] **Step 6: Commit**

```bash
git add TeleportTests
git commit -m "Update existing tests for the TeleportKit module boundary, add SSHHostKeyStore tests"
```

---

### Task 6: TeleportCLICore — URL parsing, exit codes, conflict policy, folder walking

**Files:**
- Modify: `TeleportKit/Package.swift` (add `TeleportCLICore` target + test target)
- Create: `TeleportKit/Sources/TeleportCLICore/RemoteTarget.swift`
- Create: `TeleportKit/Sources/TeleportCLICore/TportExitCode.swift`
- Create: `TeleportKit/Sources/TeleportCLICore/ConflictPolicy.swift`
- Create: `TeleportKit/Sources/TeleportCLICore/FolderWalk.swift`
- Create: `TeleportKit/Tests/TeleportCLICoreTests/RemoteTargetTests.swift`
- Create: `TeleportKit/Tests/TeleportCLICoreTests/TportExitCodeTests.swift`
- Create: `TeleportKit/Tests/TeleportCLICoreTests/ConflictPolicyTests.swift`

**Interfaces:**
- Consumes: `Connection`, `RemoteClientError`, `RemotePath` (from `TeleportKit`).
- Produces:
  - `public struct RemoteTarget { public let connectionProtocol: Connection.ConnectionProtocol; public let username: String; public let host: String; public let port: Int; public let path: String; public static func parse(_ raw: String) throws -> RemoteTarget }`
  - `public enum TportUsageError: Error, CustomStringConvertible { case invalidURL(String); case missingCredentials(String) }`
  - `public enum TportExitCode: Int32 { case success = 0, generalFailure = 1, usage = 2, authFailed = 3, notFound = 4, connectionFailed = 5, hostKey = 6 }` with `public static func map(_ error: Error) -> TportExitCode`
  - `public enum TransferDirectionCLI { case get, put }`, `public enum ConflictPolicy: String, CaseIterable, ExpressibleByArgument-compatible { case overwrite, skip, ifNewer }`, `public enum ConflictDecision { case proceed, skip }`, `public func decideConflict(policy:exists:localDate:remoteDate:direction:) -> ConflictDecision`
  - `public enum FolderWalk { public static func localTree(at: URL) throws -> (dirs: [String], files: [(local: URL, relative: String)]) }` (remote-side walking is done inline in `GetCommand` since it needs an already-connected `RemoteClient`, not a pure function)

- [ ] **Step 1: Add the target to `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.8.0"),
    ],
    targets: [
        .target(name: "TeleportKit", dependencies: ["Citadel"]),
        .target(name: "TeleportCLICore", dependencies: ["TeleportKit"]),
        .testTarget(name: "TeleportCLICoreTests", dependencies: ["TeleportCLICore"]),
    ]
)
```

(`TeleportCLICore` isn't listed as a `.library` product yet — Task 7 adds the `tport` executable product and lists it as a dependency of that target directly; it doesn't need to be externally consumable on its own.)

- [ ] **Step 2: Write `RemoteTarget.swift`**

```swift
import Foundation
import TeleportKit

public struct RemoteTarget {
    public let connectionProtocol: Connection.ConnectionProtocol
    public let username: String
    public let host: String
    public let port: Int
    public let path: String

    public static func parse(_ raw: String) throws -> RemoteTarget {
        guard let components = URLComponents(string: raw), let scheme = components.scheme else {
            throw TportUsageError.invalidURL(raw)
        }
        let proto: Connection.ConnectionProtocol
        switch scheme.lowercased() {
        case "sftp": proto = .sftp
        case "ftp":  proto = .ftp
        case "ftps": proto = .ftps
        default:
            throw TportUsageError.invalidURL("Unsupported scheme '\(scheme)' — use sftp://, ftp://, or ftps://")
        }
        guard let host = components.host, !host.isEmpty else {
            throw TportUsageError.invalidURL(raw)
        }
        let username = components.user ?? NSUserName()
        let port = components.port ?? proto.defaultPort
        let path = components.path.isEmpty ? "/" : components.path
        return RemoteTarget(connectionProtocol: proto, username: username, host: host, port: port, path: path)
    }

    public func makeConnection() -> Connection {
        Connection(
            name: "\(username)@\(host)",
            host: host,
            port: port,
            username: username,
            connectionProtocol: connectionProtocol
        )
    }
}

public enum TportUsageError: Error, CustomStringConvertible {
    case invalidURL(String)
    case missingCredentials(String)

    public var description: String {
        switch self {
        case .invalidURL(let raw):
            return "Not a valid sftp://, ftp://, or ftps:// URL: \(raw)"
        case .missingCredentials(let detail):
            return detail
        }
    }
}
```

- [ ] **Step 3: Write `TportExitCode.swift`**

```swift
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
            case .notConnected:
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
```

- [ ] **Step 4: Write `ConflictPolicy.swift`**

```swift
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
```

- [ ] **Step 5: Write `FolderWalk.swift`** (ported from `TransferQueueViewModel.walkLocalTree`, dropping the `@MainActor`/`Preferences` coupling — pure function):

```swift
import Foundation
import TeleportKit

public enum FolderWalkError: Error, CustomStringConvertible {
    case tooLarge(limit: Int)
    case unreadable(String)
    case unsafeName(String)

    public var description: String {
        switch self {
        case .tooLarge(let limit):
            return "Folder contains more than \(limit) items. Transfer it in smaller pieces (--max-items)."
        case .unreadable(let name):
            return "Could not read the contents of \(name)."
        case .unsafeName(let name):
            return "'\(name)' contains characters that aren't allowed."
        }
    }
}

public enum FolderWalk {
    public static let defaultLimit = 2000

    /// Symlinks are skipped — following them risks cycles and surprising escapes
    /// from the transferred tree, same rationale as the GUI's folder transfer.
    public static func localTree(
        at folderURL: URL,
        limit: Int = defaultLimit
    ) throws -> (dirs: [String], files: [(local: URL, relative: String)]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw FolderWalkError.unreadable(folderURL.lastPathComponent)
        }

        var dirs: [String] = []
        var files: [(local: URL, relative: String)] = []
        let baseCount = folderURL.standardizedFileURL.pathComponents.count

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let components = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            guard !components.isEmpty,
                  components.allSatisfy({ RemotePath.sanitizedFilename($0) != nil }) else { continue }
            let relative = components.joined(separator: "/")
            if vals?.isDirectory == true {
                dirs.append(relative)
            } else {
                files.append((url, relative))
            }
            if dirs.count + files.count > limit {
                throw FolderWalkError.tooLarge(limit: limit)
            }
        }
        return (dirs, files)
    }
}
```

- [ ] **Step 6: Write the tests**

```swift
// TeleportKit/Tests/TeleportCLICoreTests/RemoteTargetTests.swift
import XCTest
import TeleportKit
@testable import TeleportCLICore

final class RemoteTargetTests: XCTestCase {
    func test_parse_sftpWithUserAndPort() throws {
        let t = try RemoteTarget.parse("sftp://alice@example.com:2222/var/www")
        XCTAssertEqual(t.connectionProtocol, .sftp)
        XCTAssertEqual(t.username, "alice")
        XCTAssertEqual(t.host, "example.com")
        XCTAssertEqual(t.port, 2222)
        XCTAssertEqual(t.path, "/var/www")
    }

    func test_parse_defaultsPortFromProtocol() throws {
        let t = try RemoteTarget.parse("ftp://example.com/pub")
        XCTAssertEqual(t.port, 21)
    }

    func test_parse_defaultsPathToRoot() throws {
        let t = try RemoteTarget.parse("sftp://example.com")
        XCTAssertEqual(t.path, "/")
    }

    func test_parse_rejectsUnsupportedScheme() {
        XCTAssertThrowsError(try RemoteTarget.parse("http://example.com/")) { error in
            XCTAssertTrue(error is TportUsageError)
        }
    }

    func test_parse_rejectsMissingHost() {
        XCTAssertThrowsError(try RemoteTarget.parse("sftp:///path")) { error in
            XCTAssertTrue(error is TportUsageError)
        }
    }
}
```

```swift
// TeleportKit/Tests/TeleportCLICoreTests/TportExitCodeTests.swift
import XCTest
import TeleportKit
@testable import TeleportCLICore

final class TportExitCodeTests: XCTestCase {
    func test_map_usageError() {
        XCTAssertEqual(TportExitCode.map(TportUsageError.invalidURL("x")), .usage)
    }

    func test_map_authFailure() {
        XCTAssertEqual(TportExitCode.map(RemoteClientError.authenticationFailed), .authFailed)
        XCTAssertEqual(TportExitCode.map(RemoteClientError.permissionDenied), .authFailed)
    }

    func test_map_notFound() {
        XCTAssertEqual(TportExitCode.map(RemoteClientError.fileNotFound("/x")), .notFound)
    }

    func test_map_hostKeyCases() {
        XCTAssertEqual(
            TportExitCode.map(RemoteClientError.hostKeyUntrusted(host: "h", port: 22, fingerprint: "f")),
            .hostKey
        )
        XCTAssertEqual(
            TportExitCode.map(RemoteClientError.hostKeyMismatch(host: "h", port: 22, expected: "a", actual: "b")),
            .hostKey
        )
    }

    func test_map_unknownErrorFallsBackToGeneralFailure() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(TportExitCode.map(SomeOtherError()), .generalFailure)
    }
}
```

```swift
// TeleportKit/Tests/TeleportCLICoreTests/ConflictPolicyTests.swift
import XCTest
@testable import TeleportCLICore

final class ConflictPolicyTests: XCTestCase {
    func test_noConflict_alwaysProceeds() {
        XCTAssertEqual(
            decideConflict(policy: .skip, exists: false, localDate: nil, remoteDate: nil, direction: .get),
            .proceed
        )
    }

    func test_overwrite_alwaysProceeds() {
        XCTAssertEqual(
            decideConflict(policy: .overwrite, exists: true, localDate: nil, remoteDate: nil, direction: .get),
            .proceed
        )
    }

    func test_skip_alwaysSkips() {
        XCTAssertEqual(
            decideConflict(policy: .skip, exists: true, localDate: Date(), remoteDate: Date(), direction: .put),
            .skip
        )
    }

    func test_ifNewer_get_proceedsWhenRemoteIsNewer() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: older, remoteDate: newer, direction: .get),
            .proceed
        )
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: newer, remoteDate: older, direction: .get),
            .skip
        )
    }

    func test_ifNewer_put_proceedsWhenLocalIsNewer() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: newer, remoteDate: older, direction: .put),
            .proceed
        )
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: older, remoteDate: newer, direction: .put),
            .skip
        )
    }
}
```

- [ ] **Step 7: Run the new tests**

Run: `cd TeleportKit && swift test --filter TeleportCLICoreTests`
Expected: all tests pass, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add TeleportKit
git commit -m "Add TeleportCLICore: URL parsing, exit codes, conflict policy, folder walking"
```

---

### Task 7: The `tport` executable — root command, auth/host-key options, `ls`/`stat`/`test`

**Files:**
- Modify: `TeleportKit/Package.swift` (add swift-argument-parser dependency + `tport` executable target)
- Create: `TeleportKit/Sources/tport/Tport.swift` (root command)
- Create: `TeleportKit/Sources/tport/AuthOptions.swift`
- Create: `TeleportKit/Sources/tport/GlobalOptions.swift`
- Create: `TeleportKit/Sources/tport/Run.swift` (shared error → stderr → exit-code helper)
- Create: `TeleportKit/Sources/tport/LsCommand.swift`
- Create: `TeleportKit/Sources/tport/JSONOutput.swift`
- Create: `TeleportKit/Sources/tport/StatCommand.swift`
- Create: `TeleportKit/Sources/tport/TestCommand.swift`

**Interfaces:**
- Consumes: `RemoteTarget`, `TportExitCode`, `TportUsageError` (Task 6); `RemoteClient`, `RemoteClientError`, `FTPClient`, `SFTPClient`, `SSHHostKeyStore`, `FileItem` (`TeleportKit`).
- Produces: `AuthOptions.resolvePassword() throws -> String`, `AuthOptions.makeClient(for: RemoteTarget) -> RemoteClient`, `runTportCommand(_ body: () async throws -> Void) async -> Never` (prints errors, calls `exit` with the mapped code) — later tasks' commands (`get`/`put`/etc.) reuse both.

- [ ] **Step 1: Add the executable target**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleportKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeleportKit", targets: ["TeleportKit"]),
        .executable(name: "tport", targets: ["tport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", from: "0.8.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "TeleportKit", dependencies: ["Citadel"]),
        .target(name: "TeleportCLICore", dependencies: ["TeleportKit"]),
        .testTarget(name: "TeleportCLICoreTests", dependencies: ["TeleportCLICore"]),
        .executableTarget(
            name: "tport",
            dependencies: [
                "TeleportKit",
                "TeleportCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Write `GlobalOptions.swift`**

```swift
import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Suppress non-error output.")
    var quiet = false
}
```

- [ ] **Step 3: Write `AuthOptions.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct AuthOptions: ParsableArguments {
    @Option(name: .long, help: "Password (prefer TELEPORT_PASSWORD or --password-stdin over this — it's visible in `ps`).")
    var password: String?

    @Flag(name: .long, help: "Read the password as a single line from stdin.")
    var passwordStdin = false

    @Option(name: .long, help: "Path to an SFTP private key (unencrypted OpenSSH ed25519 or RSA).")
    var identity: String?

    @Option(name: .long, help: "Path to the known-hosts trust file. Defaults to ~/.teleport/known_hosts.json.")
    var knownHosts: String?

    @Flag(name: .long, help: "Trust and save an unknown SSH host key instead of failing closed.")
    var acceptNewHostkey = false

    func resolvePassword() throws -> String {
        if passwordStdin {
            guard let line = readLine(strippingNewline: true) else {
                throw TportUsageError.missingCredentials("--password-stdin was set but stdin produced no line")
            }
            return line
        }
        if let password { return password }
        if let env = ProcessInfo.processInfo.environment["TELEPORT_PASSWORD"] { return env }
        return ""   // anonymous FTP, or SFTP key auth (buildAuthMethod ignores the password when a key is set)
    }

    private static var defaultKnownHostsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teleport/known_hosts.json")
    }

    func makeHostKeyStore() -> SSHHostKeyStore {
        let url = knownHosts.map { URL(fileURLWithPath: $0) } ?? Self.defaultKnownHostsURL
        return SSHHostKeyStore(storeURL: url)
    }

    func makeClient(for target: RemoteTarget) throws -> RemoteClient {
        var connection = target.makeConnection()
        if let identity { connection.sshKeyPath = identity }
        let password = try resolvePassword()

        switch target.connectionProtocol {
        case .sftp:
            return SFTPClient(
                connection: connection,
                password: password,
                hostKeyStore: makeHostKeyStore(),
                onUnknownHostKey: { [acceptNewHostkey] _, _, _ in acceptNewHostkey }
            )
        case .ftp, .ftps:
            return FTPClient(connection: connection, password: password)
        }
    }
}
```

- [ ] **Step 4: Write `Run.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore

/// Runs `body`, and on failure prints "error: ..." to stderr and throws the
/// ArgumentParser `ExitCode` matching `TportExitCode.map(error)` — the one
/// mechanism ArgumentParser's `main()` honors for a non-1 process exit code.
func runTport(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
        throw ExitCode(TportExitCode.map(error).rawValue)
    }
}

private func describe(_ error: Error) -> String {
    if let described = error as? CustomStringConvertible { return described.description }
    if let localized = error as? LocalizedError, let d = localized.errorDescription { return d }
    return String(describing: error)
}
```

- [ ] **Step 5: Write `Tport.swift`**

```swift
import ArgumentParser

@main
struct Tport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tport",
        abstract: "Scriptable FTP/FTPS/SFTP client — the Teleport CLI.",
        subcommands: [
            LsCommand.self,
            StatCommand.self,
            TestCommand.self,
        ]
    )
}
```

(`get`, `put`, `mkdir`, `rm`, `mv`, `chmod`, `chown` are added to `subcommands` in Tasks 8–9.)

- [ ] **Step 6: Write `LsCommand.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct LsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List a remote directory.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the directory to list.")
    var url: String

    @Flag(help: "List subdirectories recursively.")
    var recursive = false

    @Flag(help: "Emit machine-readable JSON instead of a text table.")
    var json = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            let items = recursive
                ? try await listRecursive(client: client, path: target.path)
                : try await client.listDirectory(at: target.path)

            if json {
                print(try JSONOutput.encode(items))
            } else {
                for item in items.sorted(by: { $0.path < $1.path }) {
                    let size = item.isDirectory ? "-" : "\(item.size ?? 0)"
                    print("\(item.isDirectory ? "d" : "-")\t\(size)\t\(item.path)")
                }
            }
        }
    }

    private func listRecursive(client: RemoteClient, path: String) async throws -> [FileItem] {
        var result: [FileItem] = []
        var pending = [path]
        while let dir = pending.popLast() {
            let entries = try await client.listDirectory(at: dir)
            for entry in entries {
                result.append(entry)
                if entry.isDirectory && !entry.isSymlink { pending.append(entry.path) }
            }
        }
        return result
    }
}
```

- [ ] **Step 7: Write `JSONOutput.swift`** (referenced above — put it beside `LsCommand.swift`; also add it to this task's file list as a Create)

```swift
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
```

- [ ] **Step 8: Write `StatCommand.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct StatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stat", abstract: "Show details for one remote path.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the item.")
    var url: String

    @Flag(help: "Emit machine-readable JSON instead of text.")
    var json = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            guard await client.fileExists(at: target.path) else {
                throw RemoteClientError.fileNotFound(target.path)
            }
            let modified = await client.remoteModifiedDate(at: target.path)
            let item = FileItem(name: (target.path as NSString).lastPathComponent,
                                path: target.path, isDirectory: false, modifiedDate: modified)

            if json {
                print(try JSONOutput.encode(item))
            } else if !global.quiet {
                print("path:     \(item.path)")
                print("modified: \(modified.map(String.init(describing:)) ?? "unknown")")
            }
        }
    }
}
```

- [ ] **Step 9: Write `TestCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Check connectivity and authentication only.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL to test.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            await client.disconnect()
            if !global.quiet { print("ok") }
        }
    }
}
```

- [ ] **Step 10: Build**

Run: `cd TeleportKit && swift build`
Expected: `Build complete!`

- [ ] **Step 11: Commit**

```bash
git add TeleportKit
git commit -m "Add tport executable: root command, auth/host-key options, ls/stat/test"
```

---

### Task 8: `get`/`put` with recursive transfer, resume, and conflict flags

**Files:**
- Create: `TeleportKit/Sources/tport/ProgressPrinter.swift`
- Create: `TeleportKit/Sources/tport/ConflictPolicy+ArgumentParser.swift`
- Create: `TeleportKit/Sources/tport/GetCommand.swift`
- Create: `TeleportKit/Sources/tport/PutCommand.swift`
- Modify: `TeleportKit/Sources/tport/Tport.swift` (add `GetCommand.self, PutCommand.self` to `subcommands`)

**Interfaces:**
- Consumes: `FolderWalk.localTree`, `decideConflict`, `ConflictPolicy`, `TransferDirectionCLI` (Task 6); `RemoteClient.download/upload/listDirectory/fileExists/remoteModifiedDate/createDirectory` (`TeleportKit`); `AuthOptions`, `runTport` (Task 7).

- [ ] **Step 1: Write `ProgressPrinter.swift`**

```swift
import Foundation

/// Prints a single updating progress line to stderr, only when stderr is a
/// TTY — piping/cron output stays clean with no partial-line noise.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` of a
/// Sendable type, and FTPClient/SFTPClient invoke the progress closure
/// synchronously and sequentially within their own actor, never concurrently
/// — there's no actual shared mutable state for the compiler to protect.
final class ProgressPrinter: @unchecked Sendable {
    private let isTTY = isatty(STDERR_FILENO) != 0
    private let label: String

    init(label: String) { self.label = label }

    func update(bytes: Int64, total: Int64) {
        guard isTTY else { return }
        let pct = total > 0 ? Int(Double(bytes) / Double(total) * 100) : 0
        FileHandle.standardError.write(Data("\r\(label): \(pct)% (\(bytes)/\(total) bytes)".utf8))
    }

    func finish() {
        guard isTTY else { return }
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
```

- [ ] **Step 2: Write `ConflictPolicy+ArgumentParser.swift`.** `TeleportCLICore` deliberately doesn't depend on `swift-argument-parser` (it stays framework-free and fast to test), so `ConflictPolicy` can't declare `ExpressibleByArgument` conformance where it's defined. ArgumentParser provides a default `ExpressibleByArgument` implementation for any `RawRepresentable` enum with `RawValue == String` — declaring the (empty) conformance here, in the module that actually imports ArgumentParser, is enough to pick it up:

```swift
import ArgumentParser
import TeleportCLICore

extension ConflictPolicy: ExpressibleByArgument {}
```

Without this, `@Option var onConflict: ConflictPolicy = .skip` in the commands below fails to compile ("type 'ConflictPolicy' does not conform to protocol 'ExpressibleByArgument'").

- [ ] **Step 3: Write `PutCommand.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct PutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "put", abstract: "Upload a local file or (with --recursive) folder.")

    @Argument(help: "Local file or folder to upload.")
    var local: String

    @Argument(help: "Destination sftp://, ftp://, or ftps:// URL.")
    var url: String

    @Flag(help: "Upload a folder recursively.")
    var recursive = false

    @Flag(help: "Resume an interrupted upload from the remote file's current size.")
    var resume = false

    @Option(help: "Conflict handling when the destination already exists: overwrite, skip, or ifNewer.")
    var onConflict: ConflictPolicy = .skip

    @Option(help: "Safety cap on files in a recursive upload.")
    var maxItems: Int = FolderWalk.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let localURL = URL(fileURLWithPath: local)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if recursive {
                try await putFolder(client: client, localURL: localURL, remoteParent: target.path)
            } else {
                try await putFile(client: client, localURL: localURL, remotePath: target.path)
            }
        }
    }

    private func putFile(client: RemoteClient, localURL: URL, remotePath: String) async throws {
        let exists = await client.fileExists(at: remotePath)
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let remoteDate = await client.remoteModifiedDate(at: remotePath)
        let decision = decideConflict(policy: onConflict, exists: exists, localDate: localDate, remoteDate: remoteDate, direction: .put)
        guard decision == .proceed else {
            if !global.quiet { FileHandle.standardError.write(Data("skipped (exists): \(remotePath)\n".utf8)) }
            return
        }
        let printer = ProgressPrinter(label: localURL.lastPathComponent)
        try await client.upload(from: localURL, remotePath: remotePath, resume: resume) { bytes, total in
            printer.update(bytes: bytes, total: total)
        }
        printer.finish()
        if !global.quiet { print(remotePath) }
    }

    private func putFolder(client: RemoteClient, localURL: URL, remoteParent: String) async throws {
        guard let folderName = RemotePath.sanitizedFilename(localURL.lastPathComponent) else {
            throw FolderWalkError.unsafeName(localURL.lastPathComponent)
        }
        let (dirs, files) = try FolderWalk.localTree(at: localURL, limit: maxItems)
        let sep = remoteParent.hasSuffix("/") ? "" : "/"
        let root = "\(remoteParent)\(sep)\(folderName)"

        try? await client.createDirectory(at: root)
        for dir in dirs.sorted() {
            try? await client.createDirectory(at: "\(root)/\(dir)")
        }
        for (local, relative) in files {
            try await putFile(client: client, localURL: local, remotePath: "\(root)/\(relative)")
        }
    }
}
```

- [ ] **Step 4: Write `GetCommand.swift`**

```swift
import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Download a remote file or (with --recursive) folder.")

    @Argument(help: "Source sftp://, ftp://, or ftps:// URL.")
    var url: String

    @Argument(help: "Local destination file or folder.")
    var local: String

    @Flag(help: "Download a folder recursively.")
    var recursive = false

    @Flag(help: "Resume an interrupted download from the local file's current size.")
    var resume = false

    @Option(help: "Conflict handling when the destination already exists: overwrite, skip, or ifNewer.")
    var onConflict: ConflictPolicy = .skip

    @Option(help: "Safety cap on files in a recursive download.")
    var maxItems: Int = FolderWalk.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let localURL = URL(fileURLWithPath: local)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if recursive {
                try await getFolder(client: client, remotePath: target.path, into: localURL, limit: maxItems)
            } else {
                try await getFile(client: client, remotePath: target.path, localURL: localURL)
            }
        }
    }

    private func getFile(client: RemoteClient, remotePath: String, localURL: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: localURL.path)
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let remoteDate = await client.remoteModifiedDate(at: remotePath)
        let decision = decideConflict(policy: onConflict, exists: exists, localDate: localDate, remoteDate: remoteDate, direction: .get)
        guard decision == .proceed else {
            if !global.quiet { FileHandle.standardError.write(Data("skipped (exists): \(localURL.path)\n".utf8)) }
            return
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let printer = ProgressPrinter(label: localURL.lastPathComponent)
        try await client.download(remotePath: remotePath, to: localURL, resume: resume) { bytes, total in
            printer.update(bytes: bytes, total: total)
        }
        printer.finish()
        if !global.quiet { print(localURL.path) }
    }

    private func getFolder(client: RemoteClient, remotePath: String, into localParent: URL, limit: Int) async throws {
        let folderName = (remotePath as NSString).lastPathComponent
        guard let safeName = RemotePath.sanitizedFilename(folderName) else {
            throw FolderWalkError.unsafeName(folderName)
        }
        var pendingDirs: [(remote: String, local: URL)] = [(remotePath, localParent.appending(component: safeName))]
        var files: [(remote: String, local: URL)] = []

        while let (remoteDir, localDir) = pendingDirs.popLast() {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            for item in try await client.listDirectory(at: remoteDir) {
                guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                let childLocal = localDir.appending(component: name)
                guard RemotePath.isContained(childLocal, in: localDir) else { continue }
                if item.isSymlink { continue }
                if item.isDirectory {
                    pendingDirs.append((item.path, childLocal))
                } else {
                    files.append((item.path, childLocal))
                }
                if files.count + pendingDirs.count > limit {
                    throw FolderWalkError.tooLarge(limit: limit)
                }
            }
        }
        for (remote, local) in files {
            try await getFile(client: client, remotePath: remote, localURL: local)
        }
    }
}
```

- [ ] **Step 5: Register the subcommands** — update `Tport.swift`'s `subcommands` array:

```swift
subcommands: [
    LsCommand.self,
    StatCommand.self,
    GetCommand.self,
    PutCommand.self,
    TestCommand.self,
],
```

- [ ] **Step 6: Build**

Run: `cd TeleportKit && swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add TeleportKit
git commit -m "Add tport get/put with recursive transfer, resume, and conflict flags"
```

---

### Task 9: `mkdir`/`rm`/`mv`/`chmod`/`chown`

**Files:**
- Create: `TeleportKit/Sources/tport/MkdirCommand.swift`
- Create: `TeleportKit/Sources/tport/RmCommand.swift`
- Create: `TeleportKit/Sources/tport/MvCommand.swift`
- Create: `TeleportKit/Sources/tport/ChmodCommand.swift`
- Create: `TeleportKit/Sources/tport/ChownCommand.swift`
- Modify: `TeleportKit/Sources/tport/Tport.swift` (register all five)

**Interfaces:**
- Consumes: `RemoteClient.createDirectory/delete/rename/setPermissions/setOwnership` (`TeleportKit`); `AuthOptions`, `runTport`, `RemoteTarget` (Task 7).

- [ ] **Step 1: Write `MkdirCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore
import TeleportKit

struct MkdirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mkdir", abstract: "Create a remote directory.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the directory to create.")
    var url: String

    @Flag(name: .shortAndLong, help: "Create intermediate parent directories as needed.")
    var parents = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if parents {
                var accumulated = ""
                for component in target.path.split(separator: "/") {
                    accumulated += "/\(component)"
                    try? await client.createDirectory(at: accumulated)
                }
            } else {
                try await client.createDirectory(at: target.path)
            }
        }
    }
}
```

- [ ] **Step 2: Write `RmCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore
import TeleportKit

struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a remote file or (with --recursive) directory tree.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL to delete.")
    var url: String

    @Flag(help: "Delete a directory and everything under it.")
    var recursive = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if recursive {
                try await deleteRecursive(client: client, path: target.path)
            } else {
                try await client.delete(at: target.path, isDirectory: false)
            }
        }
    }

    private func deleteRecursive(client: RemoteClient, path: String) async throws {
        let entries = try? await client.listDirectory(at: path)
        if let entries {
            for entry in entries {
                if entry.isDirectory && !entry.isSymlink {
                    try await deleteRecursive(client: client, path: entry.path)
                } else {
                    try await client.delete(at: entry.path, isDirectory: false)
                }
            }
        }
        try await client.delete(at: path, isDirectory: true)
    }
}
```

- [ ] **Step 3: Write `MvCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore
import TeleportKit

struct MvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mv", abstract: "Rename or move a remote file, within a single connection.")

    @Argument(help: "Source sftp://, ftp://, or ftps:// URL.")
    var source: String

    @Argument(help: "Destination URL — must be the same scheme/host/port as source.")
    var destination: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let from = try RemoteTarget.parse(source)
            let to = try RemoteTarget.parse(destination)
            guard from.host == to.host, from.port == to.port, from.connectionProtocol == to.connectionProtocol else {
                throw TportUsageError.missingCredentials("mv requires source and destination on the same host:port")
            }
            let client = try auth.makeClient(for: from)
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try await client.rename(from: from.path, to: to.path)
        }
    }
}
```

- [ ] **Step 4: Write `ChmodCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore
import TeleportKit

struct ChmodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chmod", abstract: "Set permissions on a remote path.")

    @Argument(help: "Octal permissions, e.g. 644 or 755.")
    var octal: String

    @Argument(help: "sftp://, ftp://, or ftps:// URL.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            guard let value = Int(octal, radix: 8) else {
                throw TportUsageError.invalidURL("'\(octal)' isn't a valid octal permission (e.g. 644)")
            }
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try await client.setPermissions(value, at: target.path)
        }
    }
}
```

- [ ] **Step 5: Write `ChownCommand.swift`**

```swift
import ArgumentParser
import TeleportCLICore
import TeleportKit

struct ChownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chown", abstract: "Change ownership of a remote path (SFTP: numeric UID/GID).")

    @Argument(help: "Owner (user name for FTP, numeric UID for SFTP).")
    var owner: String

    @Argument(help: "Group (group name for FTP, numeric GID for SFTP).")
    var group: String

    @Argument(help: "sftp://, ftp://, or ftps:// URL.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try await client.setOwnership(owner: owner, group: group, at: target.path)
        }
    }
}
```

- [ ] **Step 6: Register all five in `Tport.swift`**

```swift
subcommands: [
    LsCommand.self,
    StatCommand.self,
    GetCommand.self,
    PutCommand.self,
    MkdirCommand.self,
    RmCommand.self,
    MvCommand.self,
    ChmodCommand.self,
    ChownCommand.self,
    TestCommand.self,
],
```

- [ ] **Step 7: Build and smoke-test `--help`**

```bash
cd TeleportKit
swift build
swift run tport --help
swift run tport get --help
```
Expected: builds cleanly; both `--help` invocations print usage text listing every flag defined above with no crashes.

- [ ] **Step 8: Commit**

```bash
git add TeleportKit
git commit -m "Add tport mkdir/rm/mv/chmod/chown"
```

---

### Task 10: Docker-backed CLI integration tests (written, not run) + packaging

**Files:**
- Create: `TeleportTests/CLIIntegrationTests.swift`
- Modify: `scripts/build-release.sh`

**Interfaces:**
- Consumes: the built `tport` binary via `Process`; the same docker containers documented at the top of `TransferIntegrationTests.swift`.

- [ ] **Step 1: Write `CLIIntegrationTests.swift`** — same `TELEPORT_IT=1` gate as `TransferIntegrationTests.swift`, invoking the built `tport` binary as a subprocess and asserting on stdout/exit code:

```swift
import XCTest

/// Live-server integration tests for the `tport` CLI. Skipped unless
/// `TELEPORT_IT=1` is set, with the same docker containers as
/// `TransferIntegrationTests.swift` (see that file's header for exact
/// `docker run` commands).
final class CLIIntegrationTests: XCTestCase {

    private func requireServers() throws {
        guard ProcessInfo.processInfo.environment["TELEPORT_IT"] == "1" else {
            throw XCTSkip("Set TELEPORT_IT=1 with the local docker test servers running")
        }
    }

    private func tportBinaryURL() throws -> URL {
        // Built by `swift build` in TeleportKit/ ahead of running this suite.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportTests/
            .deletingLastPathComponent()  // repo root
            .appending(path: "TeleportKit/.build/debug/tport")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Build tport first: cd TeleportKit && swift build")
        }
        return url
    }

    private func run(_ args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try tportBinaryURL()
        process.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    func test_ftp_ls_listsUploadedFile() throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(component: "hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let remotePath = "/ftp/testuser/tport-it-\(UUID().uuidString).txt"
        let put = try run(["put", file.path, "ftp://testuser:testpass@127.0.0.1:2121\(remotePath)"])
        XCTAssertEqual(put.exitCode, 0, put.stderr)

        let ls = try run(["ls", "ftp://testuser:testpass@127.0.0.1:2121/ftp/testuser", "--json"])
        XCTAssertEqual(ls.exitCode, 0, ls.stderr)
        XCTAssertTrue(ls.stdout.contains((remotePath as NSString).lastPathComponent))
    }

    func test_sftp_unknownHostKey_failsClosedWithoutAcceptFlag() throws {
        try requireServers()
        let knownHosts = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-known-hosts-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHosts) }

        let result = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path,
        ])
        XCTAssertEqual(result.exitCode, 6, result.stderr)   // TportExitCode.hostKey
    }

    func test_sftp_acceptNewHostkey_thenTrustsOnSubsequentRun() throws {
        try requireServers()
        let knownHosts = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-known-hosts-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHosts) }

        let first = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path, "--accept-new-hostkey",
        ])
        XCTAssertEqual(first.exitCode, 0, first.stderr)

        let second = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path,
        ])
        XCTAssertEqual(second.exitCode, 0, second.stderr)   // trusted from the first run, no --accept needed
    }

    func test_get_resume_producesCompleteFile() throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var data = Data(count: 500_000)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 500_000, $0.baseAddress!) }
        let original = dir.appending(component: "original.bin")
        try data.write(to: original)

        let remotePath = "/upload/tport-it-resume-\(UUID().uuidString).bin"
        let put = try run(["put", original.path, "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)", "--accept-new-hostkey"])
        XCTAssertEqual(put.exitCode, 0, put.stderr)

        let downloaded = dir.appending(component: "downloaded.bin")
        try data.prefix(200_000).write(to: downloaded)   // simulate a partial prior download

        let get = try run(["get", "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)", downloaded.path, "--resume", "--accept-new-hostkey", "--on-conflict", "overwrite"])
        XCTAssertEqual(get.exitCode, 0, get.stderr)
        XCTAssertEqual(try Data(contentsOf: downloaded), data)
    }
}
```

Add `import Security` at the top alongside `import XCTest` (for `SecRandomCopyBytes`).

- [ ] **Step 2: Update `scripts/build-release.sh`** to also build `tport` and copy it into `build/`. Insert this block right after the existing `ditto "$APP_PATH" "$FINAL_APP"` step (before the `VERSION=` line):

```bash
echo "==> building tport (Release)"
(cd "$REPO_ROOT/TeleportKit" && swift build -c release --product tport)
TPORT_BUILT="$REPO_ROOT/TeleportKit/.build/release/tport"
if [[ ! -f "$TPORT_BUILT" ]]; then
    echo "error: tport build succeeded but $TPORT_BUILT was not produced" >&2
    exit 1
fi
cp "$TPORT_BUILT" "$BUILD_DIR/tport"
echo "   $BUILD_DIR/tport"
```

- [ ] **Step 3: Verify the CLI integration test file at least compiles** (it won't run without docker + a built `tport`, but it must build alongside the rest of the test bundle):

Run: `xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" build-for-testing 2>&1 | tail -40`
Expected: `** TEST BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add TeleportTests/CLIIntegrationTests.swift scripts/build-release.sh
git commit -m "Add tport docker-backed integration tests and build packaging"
```

---

### Task 11: Final verification pass and status report

- [ ] **Step 1: Full clean build of everything**

```bash
cd /Users/jeffcaldwell/Development/Teleport
cd TeleportKit && swift build && swift test --filter TeleportCLICoreTests && cd ..
xcodegen generate --quiet
xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" build 2>&1 | tail -60
xcodebuild -project Teleport.xcodeproj -scheme Teleport -destination "platform=macOS" build-for-testing 2>&1 | tail -40
```
Expected: every step succeeds (`Build complete!`, all `TeleportCLICoreTests` pass, `** BUILD SUCCEEDED **`, `** TEST BUILD SUCCEEDED **`).

- [ ] **Step 2: Report status to the user**, explicitly noting:
  - What was verified in-session: package build, app build, test-bundle build, `TeleportCLICoreTests` (pure logic, no network).
  - What was **not** run: the docker-backed suites (`TransferIntegrationTests`, new `CLIIntegrationTests`) — real protocol round trips (FTP/SFTP transfer, resume, host-key trust/mismatch, chmod/chown against live servers) remain unverified until someone runs `TEST_RUNNER_TELEPORT_IT=1 xcodebuild … test` against the docker containers described at the top of `TransferIntegrationTests.swift`.
  - `tport` is not yet on `PATH` — installing it is `ln -s build/tport /usr/local/bin/tport` (or copy) after running `scripts/build-release.sh`.
