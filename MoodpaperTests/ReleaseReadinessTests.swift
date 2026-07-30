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

    func testViewsDoNotCallApplyMoodChangeDirectly() throws {
        // Mood-change refresh is owned by MoodStore.onActiveMoodChange via
        // WallpaperManager.requestMoodStateRefresh() (coalesced, one apply
        // per user action). A view calling applyMoodChange directly
        // reintroduces the asymmetry class from tasks/lessons.md 2026-05-25
        // or double-applies on activation.
        for viewFile in ["Moodpaper/HorizonSettingsView.swift", "Moodpaper/MoodsView.swift", "Moodpaper/UserLibraryView.swift", "Moodpaper/DashboardView.swift", "Moodpaper/ContentView.swift", "Moodpaper/LibraryView.swift"] {
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

    func testDashboardSkipButtonDoesNotUseFixedSleepForPressedState() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/DashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Task.sleep(nanoseconds: 300_000_000)"))
        XCTAssertTrue(source.contains(".onChange(of: wallpaperManager.isChangingWallpaper)"))
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

    func testWallpaperApplyDoesNotRunBlockingDesktopApplyAtUserInitiatedPriority() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/WallpaperManager.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("group.addTask(priority: .userInitiated)"))
        XCTAssertTrue(source.contains("group.addTask(priority: .utility)"))
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
}
