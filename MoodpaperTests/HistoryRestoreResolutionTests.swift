import XCTest
@testable import Moodpaper

final class HistoryRestoreResolutionTests: XCTestCase {
    func testRestoreUsesFallbackIdentifierForMissingScreenEntry() {
        let resolution = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: ["Studio Display": "morning-1"],
            activeScreenNames: ["Studio Display", "Projector"],
            primaryScreenName: "Studio Display"
        )

        guard case .resolved(let resolved, let primaryScreenName, let primaryIdentifier) = resolution else {
            return XCTFail("Expected resolved history restore")
        }

        XCTAssertEqual(resolved["Studio Display"], "morning-1")
        XCTAssertEqual(resolved["Projector"], "morning-1")
        XCTAssertEqual(primaryScreenName, "Studio Display")
        XCTAssertEqual(primaryIdentifier, "morning-1")
    }

    func testRestoreFallsBackToFirstActiveScreenWhenPrimaryIsMissing() {
        let resolution = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: [
                "Projector": "afternoon-2",
                "Studio Display": "morning-1"
            ],
            activeScreenNames: ["Projector", "Studio Display"],
            primaryScreenName: "Missing Screen"
        )

        guard case .resolved(_, let primaryScreenName, let primaryIdentifier) = resolution else {
            return XCTFail("Expected resolved history restore")
        }

        XCTAssertEqual(primaryScreenName, "Projector")
        XCTAssertEqual(primaryIdentifier, "afternoon-2")
    }

    func testRestoreFailsWhenNoActiveScreensExist() {
        let resolution = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: ["Studio Display": "morning-1"],
            activeScreenNames: [],
            primaryScreenName: "Studio Display"
        )

        XCTAssertEqual(resolution, .failed)
    }

    func testRestoreMatchesStoredNameKeysOntoDisplayIDs() {
        let resolution = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: ["Studio Display": "morning-1"],
            activeScreens: [(key: "4123456", name: "Studio Display")],
            primaryScreenKey: "4123456"
        )

        guard case .resolved(let resolved, let primaryScreenKey, let primaryIdentifier) = resolution else {
            return XCTFail("Expected stored name keys to resolve onto display IDs")
        }

        XCTAssertEqual(resolved["4123456"], "morning-1")
        XCTAssertEqual(primaryScreenKey, "4123456")
        XCTAssertEqual(primaryIdentifier, "morning-1")
    }
}
