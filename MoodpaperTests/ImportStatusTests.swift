import XCTest
@testable import Moodpaper

/// Locks the words the Library shows after an import or a delete.
///
/// These strings are the whole point of Stage 0: before it, a failed slot
/// import or a failed delete produced a console `print` and nothing on screen.
/// Routing every case through a named initializer is what makes them testable
/// instead of buried inside a `catch`.
final class ImportStatusTests: XCTestCase {

    private struct TestError: LocalizedError {
        let errorDescription: String? = "the disk went away"
    }

    // MARK: Import outcomes

    func testSuccessfulImportReportsTheCount() {
        let status = ImportStatus(
            summary: WallpaperImportSummary(discoveredCount: 3, importedCount: 3, failedCount: 0)
        )

        XCTAssertEqual(status.text, "Added 3 wallpapers.")
        XCTAssertFalse(status.isError)
    }

    func testSingleWallpaperIsNotPluralized() {
        let status = ImportStatus(
            summary: WallpaperImportSummary(discoveredCount: 1, importedCount: 1, failedCount: 0)
        )

        // The wording confirmed live in the Debug Visual Test Vibe.
        XCTAssertEqual(status.text, "Added 1 wallpaper.")
        XCTAssertFalse(status.isError)
    }

    func testPartialFailureReportsBothCounts() {
        let status = ImportStatus(
            summary: WallpaperImportSummary(discoveredCount: 3, importedCount: 2, failedCount: 1)
        )

        // The wording confirmed live when a folder containing one corrupt file
        // was dropped on the Deep Night slot.
        XCTAssertEqual(status.text, "Added 2 of 3 images. 1 could not be imported.")
        XCTAssertTrue(status.isError)
    }

    func testNothingDiscoveredIsReportedAsAnError() {
        let status = ImportStatus(
            summary: WallpaperImportSummary(discoveredCount: 0, importedCount: 0, failedCount: 0)
        )

        XCTAssertEqual(status.text, "No supported images were found.")
        XCTAssertTrue(status.isError)
    }

    // MARK: Failures

    func testImportFailureIncludesTheUnderlyingReason() {
        let status = ImportStatus(importFailure: TestError())

        XCTAssertEqual(status.text, "Import failed: the disk went away")
        XCTAssertTrue(status.isError)
    }

    /// The one Stage 0 surfacing path with no live observation — covered here
    /// rather than by manufacturing a broken file inside the app container.
    func testDeleteFailureIncludesTheUnderlyingReason() {
        let status = ImportStatus(deleteFailure: TestError())

        XCTAssertEqual(status.text, "Couldn't delete that wallpaper: the disk went away")
        XCTAssertTrue(status.isError)
    }
}
