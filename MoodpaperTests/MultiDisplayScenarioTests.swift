import XCTest
@testable import Moodpaper

final class MultiDisplayScenarioTests: XCTestCase {
    func testAllDisplayModesAreOffered() {
        XCTAssertEqual(DisplayMode.availableCases(), [.synchronized, .independent, .off])
    }

    func testHistoryReplayRoundTripsForIndependentMultiDisplayState() {
        let entryIdentifiers = [
            "Studio Display": "morning-1",
            "Projector": "afternoon-2"
        ]

        let restore = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: entryIdentifiers,
            activeScreenNames: ["Studio Display", "Projector"],
            primaryScreenName: "Studio Display"
        )

        guard case .resolved(let restoredIdentifiers, _, let primaryIdentifier) = restore else {
            return XCTFail("Expected replay to resolve for active multi-display state")
        }

        XCTAssertEqual(primaryIdentifier, "morning-1")
        XCTAssertTrue(
            WallpaperManager.wallpaperStateMatches(
                entryIdentifiersByScreen: entryIdentifiers,
                currentIdentifiersByScreen: restoredIdentifiers,
                entryIdentifier: "ignored",
                currentIdentifier: nil
            )
        )
    }

    func testUpgradedInstallCanSeedAndRecoverWithoutLiveDisplayState() throws {
        let suiteName = "HorizonTests.MultiDisplayScenario.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("midday-3", forKey: "currentWallpaperName")
        AppDelegate.UserDefaultsMigration.seedPerDisplayWallpaperIdentifiers(
            defaults: defaults,
            screenNames: ["Studio Display", "Projector"]
        )

        let seededData = try XCTUnwrap(defaults.data(forKey: "currentWallpaperIdentifiersByScreen"))
        let seededIdentifiers = try JSONDecoder().decode([String: String].self, from: seededData)

        let reconciled = WallpaperManager.resolveReconciledWallpaperState(
            storedName: defaults.string(forKey: "currentWallpaperName") ?? "",
            currentStoredIdentifier: defaults.string(forKey: "currentWallpaperIdentifier"),
            primaryScreenName: nil,
            liveIdentifiersByScreen: [:],
            displayNameForIdentifier: { _ in nil }
        )

        XCTAssertEqual(seededIdentifiers["Studio Display"], "midday-3")
        XCTAssertEqual(seededIdentifiers["Projector"], "midday-3")
        XCTAssertEqual(
            reconciled,
            .storedFallback(primaryName: "midday-3", primaryIdentifier: nil)
        )
    }

    func testIndependentDisplayRelaunchRestoreRecoversPerScreenState() {
        let storedIdentifiers = [
            "Studio Display": "morning-1",
            "Projector": "afternoon-2"
        ]

        let restore = WallpaperManager.resolveHistoryRestore(
            storedIdentifiersByScreen: storedIdentifiers,
            activeScreenNames: ["Studio Display", "Projector"],
            primaryScreenName: "Studio Display"
        )

        guard case .resolved(let restoredIdentifiers, let restoredPrimary, let primaryIdentifier) = restore else {
            return XCTFail("Expected independent display state to restore on relaunch")
        }

        XCTAssertEqual(restoredPrimary, "Studio Display")
        XCTAssertEqual(primaryIdentifier, "morning-1")
        XCTAssertEqual(restoredIdentifiers["Studio Display"], "morning-1")
        XCTAssertEqual(restoredIdentifiers["Projector"], "afternoon-2")
    }

    func testStableScreenKeyPrefersDisplayIDOverLocalizedName() {
        XCTAssertEqual(
            WallpaperManager.stableScreenKey(displayID: "69733440", localizedName: "Built-in Retina Display"),
            "69733440"
        )
        XCTAssertEqual(
            WallpaperManager.stableScreenKey(displayID: "unknown", localizedName: "Studio Display"),
            "Studio Display"
        )
        XCTAssertEqual(
            WallpaperManager.stableScreenKey(displayID: "", localizedName: "Studio Display"),
            "Studio Display"
        )
    }

    func testScreenKeyedStateRemapsLocalizedNameToDisplayID() {
        let morning = URL(fileURLWithPath: "/tmp/morning.jpg")
        let evening = URL(fileURLWithPath: "/tmp/evening.jpg")

        let remapped = WallpaperManager.reconcileScreenKeyedValues(
            existing: [
                "Built-in Retina Display": morning,
                "Studio Display": evening
            ],
            nameToKey: [
                "Built-in Retina Display": "69733440",
                "Studio Display": "4123456"
            ],
            currentKeys: ["69733440", "4123456"]
        )

        XCTAssertEqual(remapped["69733440"], morning)
        XCTAssertEqual(remapped["4123456"], evening)
        XCTAssertNil(remapped["Built-in Retina Display"])
    }

    func testScreenKeyedStatePrunesDisconnectedDisplays() {
        let morning = URL(fileURLWithPath: "/tmp/morning.jpg")
        let projector = URL(fileURLWithPath: "/tmp/projector.jpg")

        let remapped = WallpaperManager.reconcileScreenKeyedValues(
            existing: [
                "69733440": morning,
                "999999": projector
            ],
            nameToKey: ["Color LCD": "69733440"],
            currentKeys: ["69733440"]
        )

        XCTAssertEqual(remapped["69733440"], morning)
        XCTAssertNil(remapped["999999"])
    }

    func testNameKeyedScreenStateRemapsRenameThroughDisplayID() {
        let remapped = WallpaperManager.remapNameKeyedScreenValues(
            existing: [
                "Built-in Retina Display": "morning-1",
                "Projector": "afternoon-2"
            ],
            previousNameToKey: [
                "Built-in Retina Display": "69733440",
                "Projector": "8888"
            ],
            currentNameToKey: [
                "Color LCD": "69733440"
            ],
            currentNames: ["Color LCD"]
        )

        XCTAssertEqual(remapped["Color LCD"], "morning-1")
        XCTAssertNil(remapped["Built-in Retina Display"])
        XCTAssertNil(remapped["Projector"])
    }

    func testDisplayIdentityMapKeepsPreviousNamesForStillConnectedIDs() {
        let merged = WallpaperManager.mergedDisplayIdentityMap(
            previous: [
                "Built-in Retina Display": "69733440",
                "Projector": "8888"
            ],
            currentNameToKey: [
                "Color LCD": "69733440"
            ]
        )

        XCTAssertEqual(merged["Color LCD"], "69733440")
        XCTAssertEqual(merged["Built-in Retina Display"], "69733440")
        XCTAssertNil(merged["Projector"])
    }
}
