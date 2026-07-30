import XCTest
@testable import Moodpaper

/// Locks the post-pivot selection contract: the active Mood's slot folder is
/// the only wallpaper source, and an empty slot HOLDS the current wallpaper
/// (it is never an error, and nothing else is consulted). If this decision
/// grows new cases, the engine and dashboard must keep reading ONE answer —
/// that rule is what ended the "desktop disagrees with the dashboard" bug
/// class (see tasks/lessons.md 2026-05-24).
final class WallpaperSourceDecisionTests: XCTestCase {

    func testNonEmptyMoodPoolIsSelected() {
        XCTAssertEqual(
            WallpaperManager.resolveWallpaperSource(moodPoolIsEmpty: false),
            .moodPool
        )
    }

    func testEmptyMoodSlotHoldsCurrentWallpaper() {
        XCTAssertEqual(
            WallpaperManager.resolveWallpaperSource(moodPoolIsEmpty: true),
            .holdCurrent
        )
    }
}
