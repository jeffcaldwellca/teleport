import AppKit
import XCTest
@testable import Teleport

final class PreferencesTests: XCTestCase {

    private static let textSizeKey = "pref.fileListTextSize"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.textSizeKey)
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
