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
}
