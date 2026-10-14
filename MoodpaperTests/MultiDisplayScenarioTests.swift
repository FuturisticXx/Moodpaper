import XCTest
@testable import Moodpaper

final class MultiDisplayScenarioTests: XCTestCase {
    func testCurrentPoolPreservationRejectsStaleBenQWallpaper() {
        XCTAssertFalse(
            WallpaperManager.persistedWallpapersAreValidForSlot(
                persistedIdentifiersByScreen: [
                    "Built-in Display": "/assets/morning-built-in.jpg",
                    "BenQ EX2780Q, Display 3": "/assets/night-benq.jpg"
                ],
                activeScreenNames: ["Built-in Display", "BenQ EX2780Q, Display 3"],
                fallbackPrimaryIdentifier: "/assets/morning-built-in.jpg",
                validIdentifiers: ["/assets/morning-built-in.jpg", "/assets/morning-benq.jpg"]
            )
        )
    }

    func testBenQStaleConfirmationPreventsCommitUntilEveryDisplaySucceeds() {
        let expected = [
            "Built-in Display": URL(fileURLWithPath: "/assets/morning-built-in.jpg"),
            "BenQ EX2780Q, Display 3": URL(fileURLWithPath: "/assets/morning-benq.jpg")
        ]
        let stale = [
            "Built-in Display": expected["Built-in Display"]!,
            "BenQ EX2780Q, Display 3": URL(fileURLWithPath: "/assets/night-benq.jpg")
        ]
        var appliedSlot = "deep-night"
        var history: [URL] = []
        let morning = expected["Built-in Display"]!

        let partialOutcome = SlotApplyRuntime(
            setDesktopImages: { true },
            confirmDesktopImages: {
                WallpaperManager.desktopApplyConfirmationDecision(expectedURLsByScreen: expected, liveURLsByScreen: stale, elapsed: 20, timeout: 20)
            }
        ).apply()
        WallpaperManager.commitSlotTransition(outcome: partialOutcome, newSlot: "morning", newAsset: morning, appliedSlot: &appliedSlot, history: &history)
        XCTAssertEqual(partialOutcome, .confirmationTimedOut)
        XCTAssertEqual(appliedSlot, "deep-night")
        XCTAssertTrue(history.isEmpty)

        let successOutcome = SlotApplyRuntime(
            setDesktopImages: { true },
            confirmDesktopImages: {
                WallpaperManager.desktopApplyConfirmationDecision(expectedURLsByScreen: expected, liveURLsByScreen: expected, elapsed: 1, timeout: 20)
            }
        ).apply()
        WallpaperManager.commitSlotTransition(outcome: successOutcome, newSlot: "morning", newAsset: morning, appliedSlot: &appliedSlot, history: &history)
        XCTAssertEqual(successOutcome, .confirmed)
        XCTAssertEqual(appliedSlot, "morning")
        XCTAssertEqual(history, [morning])
    }
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
}
