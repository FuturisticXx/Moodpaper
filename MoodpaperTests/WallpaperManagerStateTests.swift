import XCTest
@testable import Moodpaper

final class WallpaperManagerStateTests: XCTestCase {
    func testFocusMeetingSuppressesContextualWallpaperOverrides() {
        XCTAssertTrue(
            WallpaperManager.shouldSuppressContextualWallpaperOverrides(
                focusModeEnabled: true,
                isInMeeting: true
            )
        )
        XCTAssertFalse(
            WallpaperManager.shouldSuppressContextualWallpaperOverrides(
                focusModeEnabled: true,
                isInMeeting: false
            )
        )
        XCTAssertFalse(
            WallpaperManager.shouldSuppressContextualWallpaperOverrides(
                focusModeEnabled: false,
                isInMeeting: true
            )
        )
    }

    func testSystemDNDDoesNotBlockActiveFocusMeeting() {
        XCTAssertTrue(
            WallpaperManager.shouldSkipWallpaperUpdateForDND(
                isDNDActive: true,
                respectDoNotDisturb: true,
                focusMeetingActive: false
            )
        )
        XCTAssertFalse(
            WallpaperManager.shouldSkipWallpaperUpdateForDND(
                isDNDActive: true,
                respectDoNotDisturb: true,
                focusMeetingActive: true
            )
        )
    }

    func testPauseRotationBlocksAutomaticAndManualRotationChanges() {
        XCTAssertFalse(
            WallpaperManager.shouldAllowWallpaperChange(
                pauseRotationEnabled: true,
                userInitiated: false
            )
        )
        XCTAssertFalse(
            WallpaperManager.shouldAllowWallpaperChange(
                pauseRotationEnabled: true,
                userInitiated: true
            )
        )
        XCTAssertTrue(
            WallpaperManager.shouldAllowWallpaperChange(
                pauseRotationEnabled: false,
                userInitiated: false
            )
        )
    }

    func testHistoryTriggerDisplayNamesAreReadable() {
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "scheduledTick"), "Schedule")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherUpdate"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "moodChange"), "Vibe")
        // Legacy persisted entries from the pre-pivot vibe system.
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "vibeChange"), "Vibe")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "manual"), "Manual")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: nil), "Auto")
        // Raw internal ids must never reach the history UI.
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherSyncEnabled"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherSyncEnabledDeferred"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherSyncEnabledTimeout"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherSyncDisabled"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "weatherReconcile"), "Weather")
        XCTAssertEqual(WallpaperHistoryEntry.triggerDisplayName(for: "restoreHistoryEntry"), "Manual")
    }

    func testHistoryEntryDecodesWithoutTriggerForExistingUsers() throws {
        let json = """
        [{
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": 782000000,
            "wallpaperName": "morning-1",
            "slotID": "morning",
            "slotDisplayName": "Morning"
        }]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([WallpaperHistoryEntry].self, from: json)
        XCTAssertNil(decoded[0].trigger)
        XCTAssertEqual(decoded[0].triggerDisplayName, "Auto")
    }

    func testCountdownUpdatePublishesOnlyWhenDisplayedValueChanges() {
        XCTAssertFalse(
            WallpaperManager.shouldPublishCountdownUpdate(
                current: "12m",
                next: "12m"
            )
        )

        XCTAssertTrue(
            WallpaperManager.shouldPublishCountdownUpdate(
                current: "12m",
                next: "11m"
            )
        )
    }

    func testWallpaperSlotDetectionUsesManifestBeforeFilenamePrefix() {
        let slots = [
            "evening-17": "evening",
            "weather-rain-11": "morning",
            "mood-focus-13": "midday",
            "night-01": "evening",
            "sunset-01": "dusk"
        ]

        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "evening-17",
                currentSlot: "evening",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "weather-rain-11",
                currentSlot: "morning",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "mood-focus-13",
                currentSlot: "midday",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "night-01",
                currentSlot: "evening",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "sunset-01",
                currentSlot: "dusk",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
        XCTAssertFalse(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "sunset-01",
                currentSlot: "evening",
                manifestSlotForIdentifier: { slots[$0] }
            )
        )
    }

    func testWallpaperSlotDetectionFallsBackToLegacyPrefixWithoutManifestEntry() {
        XCTAssertTrue(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "evening-legacy",
                currentSlot: "evening",
                manifestSlotForIdentifier: { _ in nil }
            )
        )
        XCTAssertFalse(
            WallpaperManager.wallpaperBelongsToCurrentSlot(
                identifier: "night-legacy",
                currentSlot: "evening",
                manifestSlotForIdentifier: { _ in nil }
            )
        )
    }

    func testDebugURLSummaryIsStableAndReadable() {
        let summary = WallpaperManager.debugURLSummary([
            "Studio Display": URL(fileURLWithPath: "/tmp/evening-1.jpg"),
            "Built-in Retina Display": URL(fileURLWithPath: "/tmp/weather-rain-2.jpg")
        ])

        XCTAssertEqual(
            summary,
            "Built-in Retina Display=weather-rain-2.jpg,Studio Display=evening-1.jpg"
        )
        XCTAssertEqual(WallpaperManager.debugURLSummary([:]), "none")
    }

    func testPreviewURLSelectionFallsBackWhenLiveDesktopURLIsUnreadable() {
        let liveURL = URL(fileURLWithPath: "/outside-sandbox/prepared.jpg")
        let fallbackURL = URL(fileURLWithPath: "/bundle/mood-natural-1.jpg")

        let selected = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: liveURL,
            fallbackURL: fallbackURL,
            isReadable: { $0 == fallbackURL }
        )

        XCTAssertEqual(selected, fallbackURL)
    }

    func testPreviewURLPrefersAuthoritativeOverLaggingLiveDesktop() {
        // Right after Horizon applies a wallpaper, NSWorkspace can still report the
        // PREVIOUS image. The just-applied URL must win so the preview doesn't
        // freeze on the old wallpaper (the stale Lake-Tahoe-over-rain bug).
        let applied = URL(fileURLWithPath: "/bundle/weather-rain-4.jpg")
        let staleLive = URL(fileURLWithPath: "/prepared/evening-9--1-2.jpg")
        let fallbackURL = URL(fileURLWithPath: "/bundle/evening-9.jpg")

        let selected = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: staleLive,
            fallbackURL: fallbackURL,
            authoritativeURL: applied,
            isReadable: { _ in true }
        )

        XCTAssertEqual(selected, applied)
    }

    func testPreviewURLFallsBackToLiveWhenNoAuthoritativeURL() {
        // OS-driven changes (space switch, wake, manual) pass no authoritative URL
        // and must keep reflecting the live desktop.
        let liveURL = URL(fileURLWithPath: "/prepared/weather-rain-4--1-2.jpg")
        let fallbackURL = URL(fileURLWithPath: "/bundle/evening-9.jpg")

        let selected = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: liveURL,
            fallbackURL: fallbackURL,
            authoritativeURL: nil,
            isReadable: { _ in true }
        )

        XCTAssertEqual(selected, liveURL)
    }

    func testPreviewURLIgnoresReadableDirectoryMasqueradingAsImage() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let liveDirectory = temporaryDirectory
            .appendingPathComponent("Wallpaper Shuffle--1784248599-0.jpg", isDirectory: true)
        let fallbackURL = temporaryDirectory
            .appendingPathComponent("fallback.jpg")
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: fallbackURL.path, contents: Data("fallback".utf8)))
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let selected = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: liveDirectory,
            fallbackURL: fallbackURL
        )

        XCTAssertEqual(selected, fallbackURL)
    }

    func testPreparedWallpaperBaseIdentifierStripsFingerprintAcrossSandboxPaths() {
        let containerURL = URL(fileURLWithPath: "/Users/example/Library/Containers/com.2DaMax.Moodpaper/Data/Library/Application Support/Moodpaper/PreparedWallpapers/mood-natural-5--1778450544-925495.jpg")
        let unsandboxedURL = URL(fileURLWithPath: "/Users/example/Library/Application Support/Moodpaper/PreparedWallpapers/evening-5--1778908796-1040417.jpg")

        XCTAssertEqual(WallpaperManager.preparedWallpaperBaseIdentifier(from: containerURL), "mood-natural-5")
        XCTAssertEqual(WallpaperManager.preparedWallpaperBaseIdentifier(from: unsandboxedURL), "evening-5")
    }

    func testPreparedWallpaperBaseIdentifierIgnoresNonPreparedPaths() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Moodpaper.app/Contents/Resources/mood-natural-5.jpg")

        XCTAssertNil(WallpaperManager.preparedWallpaperBaseIdentifier(from: bundleURL))
    }

    func testWallpaperStateMatchesRequiresExactPerDisplayState() {
        XCTAssertTrue(
            WallpaperManager.wallpaperStateMatches(
                entryIdentifiersByScreen: [
                    "Studio Display": "morning-1",
                    "Projector": "afternoon-2"
                ],
                currentIdentifiersByScreen: [
                    "Studio Display": "morning-1",
                    "Projector": "afternoon-2"
                ],
                entryIdentifier: "ignored",
                currentIdentifier: "other"
            )
        )

        XCTAssertFalse(
            WallpaperManager.wallpaperStateMatches(
                entryIdentifiersByScreen: [
                    "Studio Display": "morning-1",
                    "Projector": "afternoon-2"
                ],
                currentIdentifiersByScreen: [
                    "Studio Display": "morning-1",
                    "Projector": "sunrise-3"
                ],
                entryIdentifier: "ignored",
                currentIdentifier: "other"
            )
        )
    }

    func testWallpaperStateMatchesFallsBackToLegacyIdentifier() {
        XCTAssertTrue(
            WallpaperManager.wallpaperStateMatches(
                entryIdentifiersByScreen: nil,
                currentIdentifiersByScreen: [:],
                entryIdentifier: "midday-4",
                currentIdentifier: "midday-4"
            )
        )

        XCTAssertFalse(
            WallpaperManager.wallpaperStateMatches(
                entryIdentifiersByScreen: nil,
                currentIdentifiersByScreen: [:],
                entryIdentifier: "midday-4",
                currentIdentifier: "evening-1"
            )
        )
    }

    func testResolveReconciledWallpaperStatePrefersLivePerDisplayState() {
        let result = WallpaperManager.resolveReconciledWallpaperState(
            storedName: "stored-name",
            currentStoredIdentifier: "stored-id",
            primaryScreenName: "Studio Display",
            liveIdentifiersByScreen: [
                "Studio Display": "morning-1",
                "Projector": "afternoon-2"
            ],
            displayNameForIdentifier: { identifier in
                switch identifier {
                case "morning-1": return "Morning One"
                case "afternoon-2": return "Afternoon Two"
                default: return nil
                }
            }
        )

        XCTAssertEqual(
            result,
            .live(
                primaryName: "Morning One",
                primaryIdentifier: "morning-1",
                identifiersByScreen: [
                    "Studio Display": "morning-1",
                    "Projector": "afternoon-2"
                ]
            )
        )
    }

    func testResolveReconciledWallpaperStateFallsBackToStoredStateWithoutLiveScreens() {
        let result = WallpaperManager.resolveReconciledWallpaperState(
            storedName: "stored-name",
            currentStoredIdentifier: nil,
            primaryScreenName: nil,
            liveIdentifiersByScreen: [:],
            displayNameForIdentifier: { _ in nil }
        )

        XCTAssertEqual(
            result,
            .storedFallback(primaryName: "stored-name", primaryIdentifier: nil)
        )
    }

    func testResolveReconciledWallpaperStatePreservesStoredIdentifierWhenNoLiveScreensExist() {
        let result = WallpaperManager.resolveReconciledWallpaperState(
            storedName: "stored-name",
            currentStoredIdentifier: "stored-id",
            primaryScreenName: nil,
            liveIdentifiersByScreen: [:],
            displayNameForIdentifier: { _ in nil }
        )

        XCTAssertEqual(
            result,
            .storedFallback(primaryName: "stored-name", primaryIdentifier: "stored-id")
        )
    }

    func testStateInvariantViolationsFlagMissingTrackedScreens() {
        let violations = WallpaperManager.stateInvariantViolations(
            activeScreenNames: ["Studio Display", "Projector"],
            trackedScreenNames: ["Studio Display"]
        )

        XCTAssertEqual(
            violations,
            ["per-display wallpaper state is missing one or more active screens"]
        )
    }

    // MARK: - Live desktop read staleness (sync must not regress state)

    private func staleReadInputs(
        liveIdentifier: String = "dusk-9",
        liveURLIsOwnPrepared: Bool = true,
        lastAppliedIdentifier: String? = "sunset-01",
        isChangingWallpaper: Bool = false,
        secondsSinceLastChange: TimeInterval? = 2
    ) -> Bool {
        WallpaperManager.shouldIgnoreLiveDesktopRead(
            liveIdentifier: liveIdentifier,
            liveURLIsOwnPrepared: liveURLIsOwnPrepared,
            lastAppliedIdentifier: lastAppliedIdentifier,
            isChangingWallpaper: isChangingWallpaper,
            secondsSinceLastChange: secondsSinceLastChange
        )
    }

    func testSyncIgnoresLiveReadWhileApplyIsInFlight() {
        XCTAssertTrue(staleReadInputs(isChangingWallpaper: true))
    }

    func testSyncIgnoresOwnPreparedReadContradictingRecentApply() {
        // The reported bug: Skip applied sunset-01, persist wrote sunset-01,
        // then the popover's onChange triggered a sync whose lagging
        // NSWorkspace read still returned the previous prepared dusk-9 —
        // regressing currentWallpaperName/Identifier to dusk-9.
        XCTAssertTrue(staleReadInputs())
    }

    func testSyncAcceptsOwnPreparedReadAfterSettleWindow() {
        // A different Space legitimately showing an older prepared wallpaper
        // long after our last apply must still sync (Spaces off).
        XCTAssertFalse(staleReadInputs(secondsSinceLastChange: 60))
    }

    func testSyncAcceptsExternalWallpaperImmediately() {
        // A non-prepared URL means the user changed the wallpaper outside
        // Horizon (System Settings) — never presume that read is stale.
        XCTAssertFalse(staleReadInputs(liveURLIsOwnPrepared: false))
    }

    func testSyncAcceptsReadMatchingLastApplied() {
        XCTAssertFalse(staleReadInputs(liveIdentifier: "sunset-01"))
    }

    func testSyncAcceptsReadWhenNoPriorApplyExists() {
        XCTAssertFalse(staleReadInputs(lastAppliedIdentifier: nil))
        XCTAssertFalse(staleReadInputs(secondsSinceLastChange: nil))
    }

    func testSpacesSyncOwnsConsistencyIgnoresOwnPreparedMismatchAtAnyAge() {
        // Live repro: with Sync to all Spaces ON, a Space switch let the
        // popover's sync read the not-yet-reapplied Space (own prepared
        // morning-8, 25s after the last change) and persist it while every
        // display showed night-01. The engine reapplies within 0.25s, so an
        // own-prepared mismatch is transient by construction and must never
        // be persisted, regardless of how old the last change is.
        XCTAssertTrue(
            WallpaperManager.shouldIgnoreLiveDesktopRead(
                liveIdentifier: "morning-8",
                liveURLIsOwnPrepared: true,
                lastAppliedIdentifier: "night-01",
                isChangingWallpaper: false,
                secondsSinceLastChange: 25,
                spacesSyncOwnsConsistency: true
            )
        )
        // External (non-prepared) URLs still sync — the user set a wallpaper
        // in System Settings and Horizon should adopt it.
        XCTAssertFalse(
            WallpaperManager.shouldIgnoreLiveDesktopRead(
                liveIdentifier: "/Users/x/Pictures/mine.jpg",
                liveURLIsOwnPrepared: false,
                lastAppliedIdentifier: "night-01",
                isChangingWallpaper: false,
                secondsSinceLastChange: 25,
                spacesSyncOwnsConsistency: true
            )
        )
    }

    // MARK: - Desktop apply confirmation

    func testDesktopApplyConfirmationCheckpointsBackOffInsteadOfPollingEveryHundredMilliseconds() {
        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationCheckpoints(timeout: 20),
            [0.5, 1.5, 3, 5, 7, 9, 12, 16, 20]
        )
    }

    func testDesktopApplyConfirmationCheckpointsRespectShortTimeout() {
        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationCheckpoints(timeout: 0.25),
            [0.25]
        )
        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationCheckpoints(timeout: 0),
            []
        )
    }

    func testDesktopApplyConfirmationWaitsForEveryDisplay() {
        let displayOne = URL(fileURLWithPath: "/tmp/display-one.jpg")
        let displayTwo = URL(fileURLWithPath: "/tmp/display-two.jpg")

        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationDecision(
                expectedURLsByScreen: [
                    "Display 1": displayOne,
                    "Display 2": displayTwo
                ],
                liveURLsByScreen: [
                    "Display 1": displayOne,
                    "Display 2": URL(fileURLWithPath: "/tmp/previous.jpg")
                ],
                elapsed: 0.5,
                timeout: 12
            ),
            .waiting
        )
    }

    func testDesktopApplyConfirmationCompletesWhenEveryDisplayMatches() {
        let displayOne = URL(fileURLWithPath: "/tmp/display-one.jpg")
        let displayTwo = URL(fileURLWithPath: "/tmp/display-two.jpg")

        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationDecision(
                expectedURLsByScreen: [
                    "Display 1": displayOne,
                    "Display 2": displayTwo
                ],
                liveURLsByScreen: [
                    "Display 1": displayOne,
                    "Display 2": displayTwo
                ],
                elapsed: 0.5,
                timeout: 12
            ),
            .confirmed
        )
    }

    func testDesktopApplyConfirmationStopsWaitingAtTimeout() {
        XCTAssertEqual(
            WallpaperManager.desktopApplyConfirmationDecision(
                expectedURLsByScreen: [
                    "Display 1": URL(fileURLWithPath: "/tmp/next.jpg")
                ],
                liveURLsByScreen: [
                    "Display 1": URL(fileURLWithPath: "/tmp/previous.jpg")
                ],
                elapsed: 12,
                timeout: 12
            ),
            .timedOut
        )
    }

    // MARK: - Post-skip lastSlot bookkeeping

    func testSkipRecordsWallClockSlotNotSelectionPool() {
        // Chaos-mode repro: skip at 10 PM landed a midday wallpaper; storing
        // "midday" made the next tick declare a phantom slot transition and
        // rotate again 60s after the user's pick.
        XCTAssertEqual(
            WallpaperManager.postSkipLastSlot(
                selectionSlot: "midday",
                timeBasedSlot: "evening",
                focusMeetingActive: false
            ),
            "evening"
        )
    }

    func testSkipDuringFocusMeetingRecordsFocusSlot() {
        // In a meeting the tick itself compares against the focus slot, so
        // the selection slot (already the validated focus slot) is correct.
        XCTAssertEqual(
            WallpaperManager.postSkipLastSlot(
                selectionSlot: "deep-night",
                timeBasedSlot: "midday",
                focusMeetingActive: true
            ),
            "deep-night"
        )
    }

    func testSkipFallsBackToSelectionSlotWhenNoTimeSlotIsEnabled() {
        XCTAssertEqual(
            WallpaperManager.postSkipLastSlot(
                selectionSlot: "dusk",
                timeBasedSlot: nil,
                focusMeetingActive: false
            ),
            "dusk"
        )
    }

    // MARK: - Launch preservation (launch churn fix)

    // A relaunch inside the dwell window with a slot-correct persisted
    // wallpaper must NOT rotate — the desktop already shows the right thing.
    func testLaunchPreservesPersistedWallpaperInsideDwellAndMatchingSlot() {
        XCTAssertTrue(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: "morning",
                resolvedSlot: "morning",
                secondsSinceLastChange: 600,
                minimumInterval: 3 * 3600
            )
        )
    }

    // User/custom wallpapers carry no manifest slot — they are slot-agnostic
    // and preserved while the dwell is valid.
    func testLaunchPreservesSlotAgnosticWallpaperInsideDwell() {
        XCTAssertTrue(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: nil,
                resolvedSlot: "morning",
                secondsSinceLastChange: 600,
                minimumInterval: 3 * 3600
            )
        )
    }

    func testLaunchRotatesWhenDwellExpiredWhileQuit() {
        XCTAssertFalse(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: "morning",
                resolvedSlot: "morning",
                secondsSinceLastChange: 4 * 3600,
                minimumInterval: 3 * 3600
            )
        )
    }

    func testLaunchRotatesWhenSlotMovedOnWhileQuit() {
        XCTAssertFalse(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: "morning",
                resolvedSlot: "afternoon",
                secondsSinceLastChange: 600,
                minimumInterval: 3 * 3600
            )
        )
    }

    func testLaunchRotatesOnFirstRunOrUnknownState() {
        XCTAssertFalse(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: false,
                persistedWallpaperSlot: nil,
                resolvedSlot: "morning",
                secondsSinceLastChange: nil,
                minimumInterval: 3 * 3600
            )
        )
        XCTAssertFalse(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: "morning",
                resolvedSlot: "morning",
                secondsSinceLastChange: nil,
                minimumInterval: 3 * 3600
            )
        )
    }

    // Clock rolled back while quit: distrust the persisted timestamp, rotate.
    func testLaunchRotatesOnNegativeElapsedTime() {
        XCTAssertFalse(
            WallpaperManager.shouldPreservePersistedWallpaperAtLaunch(
                hasPersistedWallpaper: true,
                persistedWallpaperSlot: "morning",
                resolvedSlot: "morning",
                secondsSinceLastChange: -60,
                minimumInterval: 3 * 3600
            )
        )
    }
}
