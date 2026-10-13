import XCTest
import TeleportKit
@testable import Teleport

/// A `RemoteClient` whose `connect()` can succeed, fail, or wait to be told which.
private final class GatedClient: RemoteClient, @unchecked Sendable {
    enum Behaviour { case succeed, fail, hold }

    private let lock = NSLock()
    private let behaviour: Behaviour
    private var gate: CheckedContinuation<Bool, Never>?
    private var _disconnects = 0
    private var _listings = 0
    var listings: Int { lock.withLock { _listings } }

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    var disconnects: Int { lock.withLock { _disconnects } }
    var isWaiting: Bool { lock.withLock { gate != nil } }

    /// Let a held `connect()` finish.
    func release(succeeding: Bool) {
        let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { gate = nil }
            return gate
        }
        waiting?.resume(returning: succeeding)
    }

    private var _connects = 0
    var connects: Int { lock.withLock { _connects } }

    func connect() async throws {
        lock.withLock { _connects += 1 }
        let ok: Bool
        switch behaviour {
        case .succeed: ok = true
        case .fail:    ok = false
        case .hold:    ok = await withCheckedContinuation { c in lock.withLock { gate = c } }
        }
        if !ok { throw RemoteClientError.connectionFailed("scripted") }
    }
    func disconnect() async { lock.withLock { _disconnects += 1 } }
    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        lock.withLock { _listings += 1 }
        return []
    }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func keepAlive() async {}
    func ping() async throws {}
    func createDirectory(at absolutePath: String) async throws {}
    func delete(at absolutePath: String, isDirectory: Bool) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func remoteModifiedDate(at remotePath: String) async -> Date? { nil }
    func setModifiedDate(_ date: Date, at remotePath: String) async {}
    func fileExists(at remotePath: String) async -> Bool { false }
}

@MainActor
final class AppStateSessionTests: XCTestCase {

    private var suiteName: String!
    private var state: AppState!
    /// Behaviour for each client the app asks for, in order (default: succeed).
    private var script: [GatedClient.Behaviour] = []
    private var clients: [GatedClient] = []

    private let alpha = Connection(name: "Alpha", host: "alpha.example.com")
    private let beta  = Connection(name: "Beta",  host: "beta.example.com")
    private let gamma = Connection(name: "Gamma", host: "gamma.example.com")

    override func setUp() async throws {
        suiteName = "teleport-tests-\(UUID().uuidString)"
        script = []
        clients = []
        state = AppState(
            connectionStore: ConnectionStore(defaults: UserDefaults(suiteName: suiteName)!),
            clientFactory: { [unowned self] _, _ in
                let client = GatedClient(script.isEmpty ? .succeed : script.removeFirst())
                clients.append(client)
                return client
            }
        )
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private var titles: [String] { state.sessions.map(state.title(for:)) }
    private var activeTitle: String? { state.activeSession.map(state.title(for:)) }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Opening

    func test_openingASecondFavourite_keepsTheFirstConnected() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)

        XCTAssertEqual(titles, ["Alpha", "Beta"])
        XCTAssertEqual(activeTitle, "Beta")
        XCTAssertEqual(clients[0].disconnects, 0)
        XCTAssertEqual(state.focusedPane, .remote)
    }

    func test_openingAFavouriteThatIsAlreadyOpen_switchesToIt_withoutReconnecting() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)

        await state.openSession(for: alpha)

        XCTAssertEqual(titles, ["Alpha", "Beta"])
        XCTAssertEqual(activeTitle, "Alpha")
        XCTAssertEqual(clients.count, 2, "No new connection for a favourite that's already open")
    }

    func test_openNewSession_opensAnotherSessionToTheSameFavourite_withNumberedTitles() async {
        await state.openSession(for: alpha)
        await state.openNewSession(for: alpha)
        await state.openSession(for: beta)

        XCTAssertEqual(titles, ["Alpha", "Alpha (2)", "Beta"])
        XCTAssertEqual(state.sessions(for: alpha).count, 2)
        XCTAssertEqual(clients.count, 3)
    }

    // MARK: - Failure

    func test_failedConnection_removesItsTab_andLeavesThePreviousSessionActive() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)
        await state.openSession(for: gamma)
        state.activate(state.sessions[0].id)        // Alpha: neither the last tab nor the newest
        script = [.fail]

        await state.openSession(for: Connection(name: "Delta", host: "delta.example.com"))

        XCTAssertEqual(titles, ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(activeTitle, "Alpha")
        XCTAssertTrue(state.showingAlert)
        XCTAssertEqual(state.alertTitle, "Connection Failed")
        XCTAssertEqual(state.focusedPane, .remote)
    }

    func test_failedFirstConnection_leavesNoSession_andFocusOnTheLocalPane() async {
        script = [.fail]
        await state.openSession(for: alpha)

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertNil(state.activeSession)
        XCTAssertEqual(state.focusedPane, .local)
    }

    /// The user gave up waiting on a slow server and went back to another
    /// tab. When the slow one finally fails, they stay where they are.
    func test_failureAfterTheUserSwitchedAway_doesNotStealFocus() async throws {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)
        script = [.hold]
        let opening = Task { await state.openSession(for: gamma) }
        try await waitUntil("gamma connecting") { self.clients.count == 3 && self.clients[2].isWaiting }
        XCTAssertEqual(activeTitle, "Gamma")

        state.activate(state.sessions[0].id)         // back to Alpha
        clients[2].release(succeeding: false)
        await opening.value

        XCTAssertEqual(titles, ["Alpha", "Beta"])
        XCTAssertEqual(activeTitle, "Alpha")
    }

    /// Closed while still connecting: whatever the connection attempt ends
    /// up doing, the tab stays gone and no error is shown for it.
    func test_closingASessionThatIsStillConnecting_dropsItQuietly() async throws {
        await state.openSession(for: alpha)
        script = [.hold]
        let opening = Task { await state.openSession(for: beta) }
        try await waitUntil("beta connecting") { self.clients.count == 2 && self.clients[1].isWaiting }

        await state.closeSession(state.sessions[1].id)
        clients[1].release(succeeding: false)
        await opening.value

        XCTAssertEqual(titles, ["Alpha"])
        XCTAssertEqual(activeTitle, "Alpha")
        XCTAssertFalse(state.showingAlert)
    }

    /// …including when it ends up succeeding: that connection must be shut
    /// again rather than left logged in with no tab.
    func test_closingASessionThatThenFinishesConnecting_disconnectsIt() async throws {
        await state.openSession(for: alpha)
        script = [.hold]
        let opening = Task { await state.openSession(for: beta) }
        try await waitUntil("beta connecting") { self.clients.count == 2 && self.clients[1].isWaiting }

        await state.closeSession(state.sessions[1].id)
        let disconnectsAtClose = clients[1].disconnects
        clients[1].release(succeeding: true)
        await opening.value

        XCTAssertEqual(titles, ["Alpha"])
        XCTAssertGreaterThan(clients[1].disconnects, disconnectsAtClose,
                             "The connection that completed after the close must be closed again")
    }

    // MARK: - Closing

    func test_closingTheActiveSession_activatesTheRightHandNeighbour_elseTheLeft() async {
        let delta = Connection(name: "Delta", host: "delta.example.com")
        await state.openSession(for: alpha)
        await state.openSession(for: beta)
        await state.openSession(for: gamma)
        await state.openSession(for: delta)

        state.activate(state.sessions[1].id)                 // Beta
        await state.closeSession(state.sessions[1].id)
        XCTAssertEqual(activeTitle, "Gamma", "Right-hand neighbour takes over")
        XCTAssertEqual(state.focusedPane, .remote)

        state.activate(state.sessions[2].id)                 // Delta, the last tab
        await state.closeSession(state.sessions[2].id)
        XCTAssertEqual(activeTitle, "Gamma", "No right-hand neighbour: the one on its left, not the first")
    }

    func test_closingABackgroundSession_leavesTheActiveOneAlone() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)

        await state.closeSession(state.sessions[0].id)

        XCTAssertEqual(titles, ["Beta"])
        XCTAssertEqual(activeTitle, "Beta")
    }

    func test_closingASession_disconnectsItsClient() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)

        await state.closeSession(state.sessions[0].id)

        XCTAssertEqual(clients[0].disconnects, 1)
        XCTAssertEqual(clients[1].disconnects, 0)
    }

    func test_closingTheLastSession_returnsFocusToTheLocalPane() async {
        await state.openSession(for: alpha)

        await state.disconnect()

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertNil(state.activeSession)
        XCTAssertEqual(state.focusedPane, .local)
    }

    // MARK: - Switching

    func test_nextAndPrevious_wrapAround() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)
        await state.openSession(for: gamma)          // active: Gamma (last)

        state.activateNextSession()
        XCTAssertEqual(activeTitle, "Alpha")
        state.activatePreviousSession()
        XCTAssertEqual(activeTitle, "Gamma")
        state.activatePreviousSession()
        XCTAssertEqual(activeTitle, "Beta")
    }

    // MARK: - Favourites

    func test_deletingAFavourite_closesAllOfItsSessions() async throws {
        await state.openSession(for: alpha)
        await state.openNewSession(for: alpha)
        await state.openSession(for: beta)

        state.delete(alpha)

        try await waitUntil("alpha's sessions closed") { self.titles == ["Beta"] }
        XCTAssertEqual(activeTitle, "Beta")
        XCTAssertEqual(clients[0].disconnects + clients[1].disconnects, 2)
    }

    // MARK: - Review fixes

    /// With "Alpha (2)" on screen, choosing Alpha again means "I'm already
    /// here", not "throw me back to the first Alpha tab".
    func test_openingTheFavouriteOfTheActiveSession_staysOnThatSession() async {
        await state.openSession(for: alpha)
        await state.openNewSession(for: alpha)
        XCTAssertEqual(activeTitle, "Alpha (2)")

        await state.openSession(for: alpha)

        XCTAssertEqual(activeTitle, "Alpha (2)")
    }

    /// The sidebar highlight follows what the user picks. It must not jump to
    /// another favourite just because a tab was closed or failed to open.
    func test_closingASession_leavesTheSidebarSelectionWhereItWas() async {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)
        XCTAssertEqual(state.selectedConnectionID, beta.id)

        await state.disconnect()                 // closes Beta, Alpha takes over

        XCTAssertEqual(activeTitle, "Alpha")
        XCTAssertEqual(state.selectedConnectionID, beta.id)
    }

    /// Uploads finishing for a server whose tab is in the background must
    /// refresh *that* session — not whichever one happens to be on screen.
    func test_uploadCompleted_refreshesTheSessionItBelongsTo_notTheVisibleOne() async throws {
        await state.openSession(for: alpha)
        await state.openSession(for: beta)          // Beta on screen
        let alphaListings = clients[0].listings, betaListings = clients[1].listings

        NotificationCenter.default.post(
            name: .transferCompleted, object: nil,
            userInfo: ["direction": "upload", "connectionID": alpha.id]
        )

        try await waitUntil("alpha refreshed") { self.clients[0].listings > alphaListings }
        XCTAssertEqual(clients[1].listings, betaListings)
    }

    /// A listing that fails because its session was closed must not log back
    /// in: that connection would belong to no tab and nobody would close it.
    func test_closedSession_doesNotReconnectToRetryAListing() async {
        script = [.succeed]
        await state.openSession(for: alpha)
        let session = state.sessions[0]
        let connectsBefore = clients[0].connects

        await state.disconnect()
        await session.browser.refresh()

        XCTAssertEqual(clients[0].connects, connectsBefore)
        XCTAssertEqual(clients[0].listings, 1, "No listing is attempted on a closed session either")
    }
}
