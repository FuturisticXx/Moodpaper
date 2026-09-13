import XCTest

final class ReleaseReadinessTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testInfoPlistDoesNotDeclareUnusedPrivacyPurposeStrings() throws {
        let plistURL = repoRoot.appendingPathComponent("Moodpaper/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertNil(plist["NSDesktopFolderUsageDescription"])
        XCTAssertNil(plist["NSLocationAlwaysAndWhenInUseUsageDescription"])
        XCTAssertNil(plist["NSUserNotificationUsageDescription"])
        XCTAssertNil(plist["NSAccessibilityUsageDescription"])
    }

    func testAppDoesNotReferencePrivateDoNotDisturbNotificationNames() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/HorizonApp.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("com.apple.notificationcenterui"))
        XCTAssertFalse(source.contains("dndDidStart"))
        XCTAssertFalse(source.contains("dndDidEnd"))
    }

    func testDashboardLinksAppleWeatherAttributionToLegalPage() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("WeatherAttribution"))
        XCTAssertTrue(source.contains("Link(destination: attribution.legalPageURL)"))
        XCTAssertTrue(source.contains("Image(systemName: \"applelogo\")"))
        XCTAssertTrue(source.contains("legalPageURL"))
    }

    func testCalendarMeetingDetectionDoesNotRequireAnActiveTimer() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/CalendarService.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("guard timer != nil"))
    }

    func testWeatherFetchDeduplicationDoesNotUsePlaceholderTaskLock() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/WeatherService.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("activeFetchTask = Task {}"))
        XCTAssertFalse(source.contains("private var activeFetchTask"))
        XCTAssertFalse(source.contains("if locationService.currentLocation != nil"))
    }

    func testLocationServiceDoesNotBypassWeatherServiceLocationSubscription() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/LocationService.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("HorizonWeatherService.shared.fetchWeather()"))
    }

    func testLibraryThumbnailsDoNotDecodeFullSizeImagesOnMain() throws {
        // Thumbnail grids must never decode full-size images synchronously
        // (NSImage(contentsOf:)) — that froze the grid when a sheet opened
        // with 15+ wallpapers. Background CGImageSource thumbnails or the
        // shared WallpaperPreviewLoader are the accepted patterns.
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSImage(contentsOf: url)"))
        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
    }

    func testWallpaperApplyHotPathKeepsOffMainWorkConcurrencyClean() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/WallpaperManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("nonisolated static func prepareWallpaperFile"))
        XCTAssertTrue(source.contains("struct SendableScreen: @unchecked Sendable"))
        XCTAssertTrue(source.contains("let screen: SendableScreen"))
        XCTAssertFalse(source.contains("let screen: NSScreen\n            let preparedURL"))
    }

    func testWallpaperEngineUsesAllDayFallbackResolution() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/WallpaperManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("MoodStore.shared.effectiveWallpapers(for: timeSlot"))
    }

    func testVibeCreationContinuesIntoAllDayWallpaperImport() throws {
        let moodsSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/MoodsView.swift"),
            encoding: .utf8
        )
        let importSource = (try? String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/MoodWallpaperImportView.swift"),
            encoding: .utf8
        )) ?? ""

        XCTAssertTrue(moodsSource.contains("MoodWallpaperImportView"))
        XCTAssertTrue(moodsSource.contains("Text(\"Vibes\")"))
        XCTAssertTrue(moodsSource.contains("Label(\"New Vibe\""))
        XCTAssertTrue(moodsSource.contains("Create Your First Vibe"))
        XCTAssertTrue(moodsSource.contains("VibeHowOftenControl"))
        XCTAssertTrue(moodsSource.contains("Start with wallpapers"))
        XCTAssertTrue(importSource.contains(#"Bring \(mood.displayName) to Life"#))
        XCTAssertTrue(importSource.contains("Choose Folder"))
        XCTAssertTrue(importSource.contains("Choose Photos"))
        XCTAssertTrue(importSource.contains("Use This Vibe"))
        XCTAssertTrue(importSource.contains("allowedContentTypes: [.folder]"))
        XCTAssertTrue(importSource.contains("allowedContentTypes: [.image]"))
        XCTAssertTrue(importSource.contains(".onDrop(of: [.fileURL]"))
    }

    func testMoodImportCollageBoundsRotatedThumbnailOverflow() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/MoodWallpaperImportView.swift"),
            encoding: .utf8
        )
        let collageStart = try XCTUnwrap(source.range(of: "private var thumbnailCollage"))
        let collageEnd = try XCTUnwrap(
            source.range(of: "private func handlePickerResult", range: collageStart.upperBound..<source.endIndex)
        )
        let collageSource = source[collageStart.lowerBound..<collageEnd.lowerBound]

        XCTAssertTrue(collageSource.contains(".frame(maxWidth: .infinity)"))
        XCTAssertTrue(collageSource.contains(".frame(height: 154)"))
        XCTAssertTrue(collageSource.contains(".clipped()"))
    }

    func testLibraryPresentsAUnifiedWallpaperGridWithoutAllDayMode() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("store.libraryItems(in: mood)"))
        XCTAssertTrue(source.contains("Play Throughout the Day"))
        XCTAssertTrue(source.contains("Use During"))
        XCTAssertTrue(source.contains("Use Now"))
        XCTAssertTrue(source.contains("Preview"))
        XCTAssertTrue(source.contains("importAllDayWallpapers"))
        XCTAssertFalse(source.contains("Text(\"All Day\")"))
        XCTAssertFalse(source.contains("Using All Day"))
        XCTAssertFalse(source.contains("onApply"))
        XCTAssertFalse(source.contains("Set as Wallpaper"))
        XCTAssertFalse(source.contains("activatePrimaryAction"))
    }

    func testViewsDoNotCallApplyMoodChangeDirectly() throws {
        // Mood-change refresh is owned by MoodStore.onActiveMoodChange via
        // WallpaperManager.requestMoodStateRefresh() (coalesced, one apply
        // per user action). A view calling applyMoodChange directly
        // reintroduces the asymmetry class from tasks/lessons.md 2026-05-25
        // or double-applies on activation.
        for viewFile in ["Moodpaper/HorizonSettingsView.swift", "Moodpaper/MoodsView.swift", "Moodpaper/UserLibraryView.swift", "Moodpaper/DashboardView.swift", "Moodpaper/ContentView.swift", "Moodpaper/LibraryView.swift", "Moodpaper/ShapeMyDayView.swift"] {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(viewFile),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("applyMoodChange()"),
                "\(viewFile) must not call applyMoodChange directly; the store owns the refresh"
            )
        }
    }

    func testDashboardNextButtonShowsManagerBackedChangingState() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Task.sleep(nanoseconds: 300_000_000)"))
        XCTAssertFalse(source.contains("@State private var isSkipping"))
        XCTAssertTrue(source.contains("if wallpaperManager.isChangingWallpaper"))
        XCTAssertTrue(source.contains("Text(\"Changing…\")"))
        XCTAssertTrue(source.contains(".disabled(wallpaperManager.isChangingWallpaper)"))
        XCTAssertTrue(source.contains("Text(\"Next\")"))
        XCTAssertFalse(source.contains("Text(\"Skip\")"))
        XCTAssertTrue(source.contains("Keep This Wallpaper"))
        XCTAssertTrue(source.contains("heroActionLabel(title: \"Resume\")"))
    }

    func testDashboardCurrentWallpaperCallbacksDeferManagerMutationsOutOfViewUpdates() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func deferWallpaperPreviewRefresh"))
        XCTAssertTrue(source.contains("private func deferWallpaperSyncAndPreviewRefresh"))
        XCTAssertFalse(source.contains(".onAppear {\n            wallpaperManager.syncCurrentWallpaperWithDesktop"))
        XCTAssertFalse(source.contains(".onChange(of: hostingScreen?.localizedName) { _, _ in\n            wallpaperManager.refreshCurrentPreview"))
    }

    func testWallpaperApplyUsesMainActorForPublicAppKitDesktopAPI() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/WallpaperManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("@MainActor\n    private static func applyWallpaperJobsOnMainActor"))
        XCTAssertTrue(source.contains("return confirmed"))
        XCTAssertFalse(source.contains("applyWallpaperJobsSerially"))
        XCTAssertFalse(source.contains("Task.detached(priority: .utility)"))
    }

    func testSlotDropTargetUsesLiveIsTargetedBinding() throws {
        // The slot card used to take onDropEntered/onDropExited closures that
        // nothing ever called, so `isDropTarget` was permanently false and the
        // highlight, border, and their animations were unreachable code. The
        // drop state must come from SwiftUI's own isTargeted binding.
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isTargeted: $isDropTarget"))
        XCTAssertFalse(source.contains("isTargeted: nil"))
        XCTAssertFalse(source.contains("onDropEntered"))
        XCTAssertFalse(source.contains("onDropExited"))
    }

    func testWallpaperImportFailuresAreSurfacedNotPrinted() throws {
        // Slot import and delete failures were swallowed into console prints,
        // and fileImporter's .failure case was dropped entirely, so a failed
        // import looked identical to nothing happening.
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(
            source.contains("print("),
            "UserLibraryView must report import and delete failures in the UI, not to the console"
        )
        XCTAssertTrue(source.contains("ImportStatusBanner"))
        XCTAssertTrue(source.contains("case .failure(let error):"))
        // Every failure goes through a named ImportStatus initializer, which is
        // what makes the wording testable. ImportStatusTests locks the strings;
        // these assertions lock the wiring that reaches them.
        XCTAssertTrue(source.contains("ImportStatus(importFailure: error)"))
        XCTAssertTrue(source.contains("ImportStatus(deleteFailure: error)"))
    }

    func testSlotImportSharesTheAllDayImportPipeline() throws {
        // One importer for All Day and slots: folder walking, per-file error
        // handling, and the summary type must not diverge between them again.
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/MoodStore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("func importWallpapers(\n        from urls: [URL],"))
        XCTAssertTrue(source.contains("private func importItems("))
        XCTAssertFalse(source.contains("importAllDayItems"))
    }

    func testSettingsNavigationDoesNotExposeDebugOrDiagnosticsSection() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/HorizonSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("SidebarSectionHeader(\"Debug\""))
        XCTAssertFalse(source.contains("SidebarItem(section: .diagnostics"))
        XCTAssertFalse(source.contains("case .diagnostics"))
    }

    func testShapeMyDayIsOptionalProgressiveDisclosureOverDetailedPeriods() throws {
        let editor = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/MoodsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(editor.contains("Shape My Day"))
        XCTAssertTrue(editor.contains("showingShapeMyDay"))
        XCTAssertTrue(editor.contains("VibeHowOftenControl"))

        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/ShapeMyDayView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Text(\"Shape My Day\")"))
        XCTAssertTrue(source.contains("All Periods"))
        XCTAssertTrue(source.contains("Using photos from this Vibe."))
        XCTAssertTrue(source.contains("Skip this time of day"))
        XCTAssertTrue(source.contains("Assign selected"))
        XCTAssertTrue(source.contains("Use During"))
        XCTAssertTrue(source.contains("dropDestination"))
        XCTAssertTrue(source.contains("accessibilityAction"))
        for name in ["Deep Night", "Dawn", "Sunrise", "Morning", "Midday", "Afternoon", "Golden Hour", "Dusk"] {
            XCTAssertTrue(source.contains("slot.displayName") || source.contains(name))
        }
        XCTAssertTrue(source.contains("ForEach(TimeSlot.allCases)"))
        XCTAssertFalse(source.contains("Anytime"))
        XCTAssertFalse(source.contains("All Day"))
        XCTAssertFalse(source.contains("applyMoodChange()"))
    }

    func testDashboardAndWallpapersRemainUnchangedByShapeMyDay() throws {
        let dashboard = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/DashboardView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(dashboard.contains("Shape My Day"))
        XCTAssertFalse(dashboard.contains("Anytime"))
        XCTAssertTrue(dashboard.contains("Keep This Wallpaper"))
        XCTAssertTrue(dashboard.contains("let cardHeight: CGFloat = 260"))

        let wallpapers = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(wallpapers.contains("Shape My Day"))
        XCTAssertFalse(wallpapers.contains("Anytime"))
        XCTAssertTrue(wallpapers.contains("Play Throughout the Day"))
        XCTAssertTrue(wallpapers.contains("Use During"))
        XCTAssertTrue(wallpapers.contains("store.libraryItems(in: mood)"))
    }
}
