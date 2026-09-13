import XCTest
@testable import Moodpaper

final class HorizonNavigationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRailDestinationsAreNowWallpapersVibesAndSettings() {
        XCTAssertEqual(
            HorizonSettingsSection.railSections.map(\.title),
            ["Now", "Wallpapers", "Vibes", "Settings"]
        )
        XCTAssertFalse(HorizonSettingsSection.railSections.contains(.schedule))
        XCTAssertFalse(HorizonSettingsSection.railSections.contains(.focusMode))
        XCTAssertFalse(HorizonSettingsSection.railSections.contains(.multiDisplay))
    }

    func testPersistedSectionMapsOntoPhase2Destinations() {
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "dashboard"), .dashboard)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "now"), .dashboard)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "library"), .library)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "wallpapers"), .library)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "moods"), .moods)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "vibes"), .moods)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "schedule"), .appSettings)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "focusMode"), .appSettings)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "multiDisplay"), .appSettings)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "appSettings"), .appSettings)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "settings"), .appSettings)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: nil), .dashboard)
        XCTAssertEqual(HorizonSettingsSection.migrating(from: "unknown"), .dashboard)
    }

    func testEmptyLibraryNavigationStillTargetsVibesAndWallpapers() throws {
        let library = try String(
            contentsOf: repoRoot.appendingPathComponent("Moodpaper/UserLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(library.contains("navigateToMoods"))
        XCTAssertTrue(library.contains("Create Your First Vibe"))

        let root = try contents("Moodpaper/HorizonSettingsView.swift")
        XCTAssertTrue(root.contains("selectedSection = .moods"))
        XCTAssertTrue(root.contains("selectedSection = .library"))
    }

    func testSidebarChromeIsPreserved() throws {
        let source = try contents("Moodpaper/HorizonSettingsView.swift")

        XCTAssertTrue(source.contains("private let sidebarWidth: CGFloat = 220"))
        XCTAssertTrue(source.contains("VibrantBackground(material: .hudWindow)"))
        XCTAssertTrue(source.contains(".frame(height: 96)"))
        XCTAssertTrue(source.contains("Text(\"Moodpaper is active\")"))
        XCTAssertTrue(source.contains("sun.horizon.fill"))
        XCTAssertTrue(source.contains("style: .continuous"))
        XCTAssertTrue(source.contains("SidebarSectionHeader(\"Wallpapers\""))
        XCTAssertTrue(source.contains("SidebarSectionHeader(\"Account\""))
        XCTAssertFalse(source.contains("Features"))
        XCTAssertFalse(source.contains("SidebarItem(section: .schedule"))
        XCTAssertFalse(source.contains("SidebarItem(section: .focusMode"))
        XCTAssertFalse(source.contains("SidebarItem(section: .multiDisplay"))
    }

    func testSettingsHostsScheduleFocusAndDisplays() throws {
        let source = try contents("Moodpaper/HorizonSettingsView.swift")
        XCTAssertTrue(source.contains("SettingsGroup(title: \"Playback and Displays\")"))
        XCTAssertTrue(source.contains("title: \"Schedule\""))
        XCTAssertTrue(source.contains("title: \"Focus Mode\""))
        XCTAssertTrue(source.contains("title: \"Displays\""))
        XCTAssertTrue(source.contains("onOpenSchedule"))
        XCTAssertTrue(source.contains("onOpenFocus"))
        XCTAssertTrue(source.contains("onOpenDisplays"))
        XCTAssertTrue(source.contains("Back to Settings"))
    }

    func testDashboardPreservesOriginalCompositionWithPlaybackActions() throws {
        let source = try contents("Moodpaper/DashboardView.swift")

        XCTAssertTrue(source.contains("WeatherCard("))
        XCTAssertTrue(source.contains("CurrentWallpaperCard("))
        XCTAssertTrue(source.contains("TimelineVisualization("))
        XCTAssertTrue(source.contains("TodayPreviewSection("))
        XCTAssertTrue(source.contains("Text(\"Today's Timeline\")"))
        XCTAssertTrue(source.contains("RecentHistorySection("))
        XCTAssertTrue(source.contains("MoodToggleCard()"))
        XCTAssertTrue(source.contains("let cardHeight: CGFloat = 260"))
        XCTAssertTrue(source.contains("Playing throughout the day"))
        XCTAssertTrue(source.contains("Keeping this wallpaper"))
        XCTAssertTrue(source.contains("Moodpaper is paused"))
        XCTAssertTrue(source.contains("Keep This Wallpaper"))
        XCTAssertTrue(source.contains("heroActionLabel(title: \"Resume\")"))
        XCTAssertTrue(source.contains("Text(\"Next\")"))
        XCTAssertFalse(source.contains("NowStatusRow("))
        XCTAssertFalse(source.contains("Unpin Wallpaper"))
        XCTAssertFalse(source.contains("Skip to next wallpaper"))
        XCTAssertFalse(source.contains(".frame(height: 360)"))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
