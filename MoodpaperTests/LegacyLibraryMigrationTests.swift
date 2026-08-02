import XCTest
@testable import Moodpaper

final class LegacyLibraryMigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeLibrary(named name: String, moods: [(id: String, name: String, images: [String])]) throws -> URL {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let moodsRoot = libraryRoot.appendingPathComponent("Moods", isDirectory: true)
        try FileManager.default.createDirectory(at: moodsRoot, withIntermediateDirectories: true)

        let catalog = moods.map {
            Mood(id: $0.id, name: $0.name, createdAt: Date(), updatedAt: Date())
        }
        try JSONEncoder().encode(catalog).write(to: moodsRoot.appendingPathComponent("moods.json"))

        for mood in moods {
            let allDay = moodsRoot
                .appendingPathComponent(mood.id, isDirectory: true)
                .appendingPathComponent("AllDay", isDirectory: true)
            try FileManager.default.createDirectory(at: allDay, withIntermediateDirectories: true)
            for image in mood.images {
                try Data("image".utf8).write(to: allDay.appendingPathComponent(image))
            }
        }
        return libraryRoot
    }

    private func moods(in libraryRoot: URL) throws -> [Mood] {
        let data = try Data(contentsOf: libraryRoot
            .appendingPathComponent("Moods", isDirectory: true)
            .appendingPathComponent("moods.json"))
        return try JSONDecoder().decode([Mood].self, from: data)
    }

    private func imageCount(in libraryRoot: URL, moodID: String) -> Int {
        let allDay = libraryRoot
            .appendingPathComponent("Moods", isDirectory: true)
            .appendingPathComponent(moodID, isDirectory: true)
            .appendingPathComponent("AllDay", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: allDay.path).count) ?? 0
    }

    // MARK: Tests

    func testImportsMoodsAndImagesIntoEmptyDestination() throws {
        let legacy = try makeLibrary(named: "legacy", moods: [
            (id: "mood-a", name: "Optimistic", images: ["one.jpg", "two.png"])
        ])
        let destination = root.appendingPathComponent("container", isDirectory: true)

        let summary = try LegacyLibraryMigration.importLibrary(from: legacy, into: destination)

        XCTAssertEqual(summary, LegacyLibraryMigration.Summary(moodCount: 1, imageCount: 2))
        XCTAssertEqual(try moods(in: destination).map(\.name), ["Optimistic"])
        XCTAssertEqual(imageCount(in: destination, moodID: "mood-a"), 2)
    }

    func testLeavesTheLegacyLibraryUntouched() throws {
        let legacy = try makeLibrary(named: "legacy", moods: [
            (id: "mood-a", name: "Optimistic", images: ["one.jpg"])
        ])
        let destination = root.appendingPathComponent("container", isDirectory: true)

        _ = try LegacyLibraryMigration.importLibrary(from: legacy, into: destination)

        XCTAssertEqual(try moods(in: legacy).map(\.id), ["mood-a"])
        XCTAssertEqual(imageCount(in: legacy, moodID: "mood-a"), 1)
    }

    func testMergesWithoutOverwritingExistingMoods() throws {
        let legacy = try makeLibrary(named: "legacy", moods: [
            (id: "shared", name: "Legacy Name", images: ["a.jpg", "b.jpg"]),
            (id: "fresh", name: "Brought Over", images: ["c.jpg"])
        ])
        let destination = try makeLibrary(named: "container", moods: [
            (id: "shared", name: "Existing Name", images: ["kept.jpg"])
        ])

        let summary = try LegacyLibraryMigration.importLibrary(from: legacy, into: destination)

        XCTAssertEqual(summary.moodCount, 1, "only the mood that did not already exist is imported")
        let names = try moods(in: destination).map(\.name)
        XCTAssertEqual(names, ["Existing Name", "Brought Over"])
        XCTAssertEqual(imageCount(in: destination, moodID: "shared"), 1, "existing mood keeps its own images")
    }

    func testRepeatedImportIsANoOp() throws {
        let legacy = try makeLibrary(named: "legacy", moods: [
            (id: "mood-a", name: "Optimistic", images: ["one.jpg"])
        ])
        let destination = root.appendingPathComponent("container", isDirectory: true)

        _ = try LegacyLibraryMigration.importLibrary(from: legacy, into: destination)
        let second = try LegacyLibraryMigration.importLibrary(from: legacy, into: destination)

        XCTAssertEqual(second, LegacyLibraryMigration.Summary.empty)
        XCTAssertEqual(try moods(in: destination).count, 1)
    }

    func testLooksLikeLibraryRejectsAnArbitraryFolder() throws {
        let legacy = try makeLibrary(named: "legacy", moods: [
            (id: "mood-a", name: "Optimistic", images: ["one.jpg"])
        ])
        let notALibrary = root.appendingPathComponent("random", isDirectory: true)
        try FileManager.default.createDirectory(at: notALibrary, withIntermediateDirectories: true)

        XCTAssertTrue(LegacyLibraryMigration.looksLikeLibrary(at: legacy))
        XCTAssertFalse(LegacyLibraryMigration.looksLikeLibrary(at: notALibrary))
    }

    func testSuggestedLegacyRootIsOutsideTheSandboxContainer() {
        let suggested = LegacyLibraryMigration.suggestedLegacyRootURL.path
        XCTAssertTrue(suggested.hasSuffix("/Library/Application Support/Moodpaper"))
        XCTAssertFalse(suggested.contains("/Library/Containers/"), "must point at the real home, not the container")
    }
}
