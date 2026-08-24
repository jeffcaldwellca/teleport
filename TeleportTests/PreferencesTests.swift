import AppKit
import XCTest
@testable import Teleport

final class PreferencesTests: XCTestCase {

    private static let textSizeKey = "pref.fileListTextSize"

    /// These tests run inside the app process, so `UserDefaults.standard` is
    /// the user's real preferences domain. Start each test from a clean slate,
    /// then put back whatever was there.
    private var savedTextSize: String?

    override func setUp() {
        super.setUp()
        savedTextSize = UserDefaults.standard.string(forKey: Self.textSizeKey)
        UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
    }

    override func tearDown() {
        if let savedTextSize {
            UserDefaults.standard.set(savedTextSize, forKey: Self.textSizeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
        }
        super.tearDown()
    }

    // MARK: - fileListTextSize

    @MainActor
    func test_fileListTextSize_defaultsToMediumWhenNothingIsStored() {
        XCTAssertEqual(Preferences.shared.fileListTextSize, .medium)
    }

    @MainActor
    func test_fileListTextSize_roundTripsEveryCaseThroughUserDefaults() {
        for size in Preferences.FileListTextSize.allCases {
            Preferences.shared.fileListTextSize = size
            XCTAssertEqual(Preferences.shared.fileListTextSize, size)
            XCTAssertEqual(UserDefaults.standard.string(forKey: Self.textSizeKey), size.rawValue)
        }
    }

    @MainActor
    func test_fileListTextSize_unknownStoredValueFallsBackToMedium() {
        UserDefaults.standard.set("gigantic", forKey: Self.textSizeKey)
        XCTAssertEqual(Preferences.shared.fileListTextSize, .medium)
    }

    /// The browser panes read the preference inside their `body`; open panes
    /// must re-render the moment Settings changes it. `@Observable` only
    /// instruments stored properties, so a computed, defaults-backed property
    /// has to opt in explicitly.
    @MainActor
    func test_fileListTextSize_changesAreObservable_soOpenPanesRerenderLive() {
        let fired = expectation(description: "observation onChange fired")
        withObservationTracking {
            _ = Preferences.shared.fileListTextSize
        } onChange: {
            fired.fulfill()
        }
        Preferences.shared.fileListTextSize = .large
        wait(for: [fired], timeout: 1)
    }

    func test_fileListTextSize_mediumIsTheSystemBodySize_soTheDefaultChangesNothing() {
        XCTAssertEqual(Preferences.FileListTextSize.medium.pointSize, NSFont.systemFontSize)
    }

    func test_fileListTextSize_pointSizeGrowsStrictlyFromSmallToExtraLarge() {
        let sizes = Preferences.FileListTextSize.allCases.map(\.pointSize)
        XCTAssertEqual(Preferences.FileListTextSize.allCases.first, .small)
        XCTAssertEqual(Preferences.FileListTextSize.allCases.last, .extraLarge)
        XCTAssertTrue(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 }, "point sizes: \(sizes)")
    }

    func test_fileListTextSize_iconAndRowMetricsGrowWithTheText() {
        let cases = Preferences.FileListTextSize.allCases
        let icons = cases.map(\.iconSize)
        let padding = cases.map(\.rowPadding)
        XCTAssertTrue(zip(icons, icons.dropFirst()).allSatisfy { $0 < $1 }, "icon sizes: \(icons)")
        XCTAssertTrue(zip(padding, padding.dropFirst()).allSatisfy { $0 <= $1 }, "row padding: \(padding)")
    }
}
