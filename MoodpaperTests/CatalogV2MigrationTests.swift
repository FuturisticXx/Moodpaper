import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Moodpaper

@MainActor
final class CatalogV2MigrationTests: XCTestCase {
    private var libraryRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogV2Tests-\(UUID().uuidString)")
        suiteName = "HorizonTests.CatalogV2.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
    }

    override func tearDown() {
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        try? FileManager.default.removeItem(at: libraryRoot)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        libraryRoot = nil
        super.tearDown()
    }

    private func makeStore() -> MoodStore {
        MoodStore(baseURL: libraryRoot, defaults: defaults)
    }

    private func writePNG(
        to url: URL,
        color: CGColor = CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testFreshCatalogImportDoesNotUseVibeFoldersAsOwnership() async throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Calm"))
        let source = libraryRoot.appendingPathComponent("source.png")
        try writePNG(to: source)

        let summary = try await store.importAllDayWallpapers(from: [source], in: vibe)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertTrue(store.usesCatalog)
        XCTAssertEqual(store.allDayWallpapers(in: vibe).count, 1)
        XCTAssertEqual(store.catalog?.assets.count, 1)
        XCTAssertEqual(store.catalog?.memberships.count, 1)
        let canonical = try XCTUnwrap(store.allDayWallpapers(in: vibe).first)
        XCTAssertTrue(canonical.path.contains("/Catalog/Assets/"))
        XCTAssertFalse(canonical.path.contains("/Moods/\(vibe.id)/AllDay/"))
    }

    func testLegacyGeneralOnlyMigratesToThroughoutTheDayMembership() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Walks"))
        let file = store.allDayFolderURL(in: vibe).appendingPathComponent("lake.png")
        try writePNG(to: file)
        defaults.set(vibe.id, forKey: MoodStore.activeMoodIDKey)
        defaults.set(6.0, forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        store.setWallpapersPerDay(6, for: vibe)

        let summary = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertEqual(summary.assetCount, 1)
        XCTAssertFalse(summary.alreadyComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "legacy file must remain")

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.usesCatalog)
        XCTAssertEqual(reloaded.activeMoodID, vibe.id)
        XCTAssertEqual(reloaded.effectiveWallpapersPerDay(for: reloaded.mood(id: vibe.id)), 6)
        XCTAssertEqual(reloaded.allDayWallpapers(in: try XCTUnwrap(reloaded.mood(id: vibe.id))).count, 1)
        XCTAssertTrue(reloaded.wallpapers(for: .morning, in: try XCTUnwrap(reloaded.mood(id: vibe.id))).isEmpty)
        XCTAssertEqual(
            reloaded.effectiveWallpapers(for: .morning, in: try XCTUnwrap(reloaded.mood(id: vibe.id))).count,
            1
        )
    }

    func testDetailedNinePeriodAssignmentsSurviveMigration() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Detailed"))
        for (index, slot) in TimeSlot.allCases.enumerated() {
            let url = store.folderURL(for: slot, in: vibe)
                .appendingPathComponent("\(slot.rawValue).png")
            try writePNG(
                to: url,
                color: CGColor(red: Double(index) / 10.0, green: 0.2, blue: 1.0 - Double(index) / 10.0, alpha: 1)
            )
        }

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let reloaded = makeStore()
        let mood = try XCTUnwrap(reloaded.mood(id: vibe.id))
        for slot in TimeSlot.allCases {
            XCTAssertEqual(reloaded.wallpaperCount(for: slot, in: mood), 1, slot.rawValue)
        }
        XCTAssertEqual(reloaded.catalog?.assets.count, TimeSlot.allCases.count)
    }

    func testSameWallpaperInMultipleLegacySlotFoldersBecomesOneAsset() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Shared slots"))
        let source = libraryRoot.appendingPathComponent("same.png")
        try writePNG(to: source)
        let dawn = store.folderURL(for: .dawn, in: vibe).appendingPathComponent("same.png")
        let morning = store.folderURL(for: .morning, in: vibe).appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: source, to: dawn)
        try FileManager.default.copyItem(at: source, to: morning)

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.catalog?.assets.count, 1)
        let mood = try XCTUnwrap(reloaded.mood(id: vibe.id))
        XCTAssertEqual(reloaded.wallpapers(for: .dawn, in: mood).count, 1)
        XCTAssertEqual(reloaded.wallpapers(for: .morning, in: mood).count, 1)
        XCTAssertEqual(
            reloaded.wallpapers(for: .dawn, in: mood).first,
            reloaded.wallpapers(for: .morning, in: mood).first
        )
    }

    func testDuplicatePhysicalCopiesWithMatchingHashAndMetadataCollapse() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Dupes"))
        let a = store.allDayFolderURL(in: vibe).appendingPathComponent("a.png")
        let b = store.allDayFolderURL(in: vibe).appendingPathComponent("b.png")
        try writePNG(to: a)
        try FileManager.default.copyItem(at: a, to: b)

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertEqual(makeStore().catalog?.assets.count, 1)
    }

    func testFilenameCollisionWithoutMatchingMetadataStaysDistinct() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Ambiguous"))
        let a = store.allDayFolderURL(in: vibe).appendingPathComponent("photo.jpg")
        let b = store.folderURL(for: .night, in: vibe).appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x01]).write(to: a)
        try Data([0xFF, 0xD8, 0xFF, 0x02]).write(to: b)

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertEqual(makeStore().catalog?.assets.count, 2)
    }

    func testTwoVibesSharingAWallpaperBecomeOneAssetTwoMemberships() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "One"))
        let second = try XCTUnwrap(store.create(name: "Two"))
        let source = libraryRoot.appendingPathComponent("shared.png")
        try writePNG(to: source)
        try FileManager.default.copyItem(
            at: source,
            to: store.allDayFolderURL(in: first).appendingPathComponent("shared.png")
        )
        try FileManager.default.copyItem(
            at: source,
            to: store.allDayFolderURL(in: second).appendingPathComponent("shared.png")
        )

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.catalog?.assets.count, 1)
        XCTAssertEqual(reloaded.catalog?.memberships.count, 2)
        let assetID = try XCTUnwrap(reloaded.catalog?.assets.first?.id)
        XCTAssertEqual(reloaded.catalog?.moodIDs(forAssetID: assetID), [first.id, second.id].sorted())
    }

    func testRemoveFromVibeKeepsAssetAndDeleteFromMoodpaperDestroysIt() async throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "One"))
        let second = try XCTUnwrap(store.create(name: "Two"))
        let source = libraryRoot.appendingPathComponent("keep.png")
        try writePNG(to: source)
        _ = try await store.importAllDayWallpapers(from: [source], in: first)
        let url = try XCTUnwrap(store.allDayWallpapers(in: first).first)
        try store.addWallpaper(url, to: second)

        XCTAssertEqual(store.catalog?.assets.count, 1)
        XCTAssertEqual(store.catalog?.memberships.count, 2)

        try store.removeWallpaper(url, from: first)
        XCTAssertTrue(store.allDayWallpapers(in: first).isEmpty)
        XCTAssertEqual(store.allDayWallpapers(in: second).count, 1)
        XCTAssertEqual(store.catalog?.assets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try store.deleteWallpaperFromMoodpaper(url)
        XCTAssertTrue(store.allDayWallpapers(in: second).isEmpty)
        XCTAssertEqual(store.catalog?.assets.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInterruptedMigrationResumesWithoutDuplicatingAssets() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Resume"))
        try writePNG(to: store.allDayFolderURL(in: vibe).appendingPathComponent("one.png"))
        try writePNG(
            to: store.folderURL(for: .dusk, in: vibe).appendingPathComponent("two.png"),
            color: CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        )

        LibraryMigration.testInterruptAfterPhase = .backupComplete
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: WallpaperCatalogFile.catalogURL(in: libraryRoot).path)
        )
        let journal = try LibraryMigration.loadJournal(from: libraryRoot)
        XCTAssertEqual(journal.phase, .backupComplete)

        let summary = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertTrue(summary.resumed)
        XCTAssertEqual(summary.assetCount, 2)
        let catalog = try LibraryMigration.loadCatalog(from: libraryRoot)
        XCTAssertTrue(catalog.isReady)
        XCTAssertEqual(catalog.assets.count, 2)
    }

    func testIdempotentRerunDoesNotCopyAgain() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Once"))
        try writePNG(to: store.allDayFolderURL(in: vibe).appendingPathComponent("one.png"))
        let first = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let second = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertTrue(second.alreadyComplete)
        XCTAssertEqual(second.assetCount, first.assetCount)
    }

    func testValidationFailurePreservesLegacyAndDoesNotPublishCatalog() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Safe"))
        let legacy = store.allDayFolderURL(in: vibe).appendingPathComponent("one.png")
        try writePNG(to: legacy)

        LibraryMigration.testCorruptStagingBeforeValidation = true
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: WallpaperCatalogFile.catalogURL(in: libraryRoot).path)
        )
        let journal = try LibraryMigration.loadJournal(from: libraryRoot)
        XCTAssertEqual(journal.phase, .aborted)
        XCTAssertNotNil(journal.lastError)
    }

    func testMixedShapeMyDayCadenceActiveVibeAndSkippedPeriodsSurvive() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Shaped"))
        store.setWallpapersPerDay(11, for: vibe)
        let lake = store.allDayFolderURL(in: vibe).appendingPathComponent("lake.png")
        try writePNG(to: lake)
        try store.assignWallpaper(lake, to: .morning, in: vibe)
        let dawnCopy = try XCTUnwrap(store.wallpapers(for: .dawn, in: vibe).first)
        try store.removeWallpaperAssignment(dawnCopy, from: .dawn, in: vibe)
        HorizonScheduleDefaults.setSlotEnabled(false, slotID: TimeSlot.evening.slotID, defaults: defaults)
        XCTAssertEqual(store.dayPartRepresentation(for: .morning, in: vibe), .mixed)

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let reloaded = makeStore()
        let mood = try XCTUnwrap(reloaded.mood(id: vibe.id))
        XCTAssertEqual(reloaded.activeMoodID, vibe.id)
        XCTAssertEqual(reloaded.effectiveWallpapersPerDay(for: mood), 11)
        XCTAssertEqual(reloaded.dayPartRepresentation(for: .morning, in: mood), .mixed)
        XCTAssertTrue(reloaded.wallpapers(for: .dawn, in: mood).isEmpty)
        XCTAssertEqual(
            reloaded.effectiveWallpapers(for: .dawn, in: mood).count,
            1
        )
        XCTAssertFalse(HorizonScheduleDefaults.isSlotEnabled(TimeSlot.evening.slotID, defaults: defaults))
        XCTAssertEqual(reloaded.wallpapers(for: .sunrise, in: mood).count, 1)
    }

    func testAddingExistingWallpaperToAnotherVibeDoesNotDuplicateTheFile() async throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "One"))
        let second = try XCTUnwrap(store.create(name: "Two"))
        let source = libraryRoot.appendingPathComponent("photo.png")
        try writePNG(to: source)
        _ = try await store.importAllDayWallpapers(from: [source], in: first)
        let url = try XCTUnwrap(store.allDayWallpapers(in: first).first)
        try store.addWallpaper(url, to: second, placement: .throughoutTheDay)
        XCTAssertEqual(store.catalog?.assets.count, 1)
        let files = try FileManager.default.contentsOfDirectory(
            at: WallpaperCatalogFile.assetsRoot(in: libraryRoot),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() != "" && !$0.lastPathComponent.hasPrefix("import-") }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(store.allDayWallpapers(in: first), store.allDayWallpapers(in: second))
    }

    func testPlaybackIdentifierRemapsLegacyPathToCanonicalFile() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Now"))
        let legacy = store.allDayFolderURL(in: vibe).appendingPathComponent("now.png")
        try writePNG(to: legacy)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let reloaded = makeStore()
        let canonical = try XCTUnwrap(reloaded.resolveCanonicalURL(forPlaybackIdentifier: legacy.path))
        XCTAssertTrue(canonical.path.contains("/Catalog/Assets/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testRelaunchAfterMigrationKeepsAssignments() throws {
        let original = makeStore()
        let vibe = try XCTUnwrap(original.create(name: "Relaunch"))
        try writePNG(to: original.folderURL(for: .goldenHour, in: vibe).appendingPathComponent("gold.png"))
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.usesCatalog)
        XCTAssertEqual(
            relaunched.wallpaperCount(for: .goldenHour, in: try XCTUnwrap(relaunched.mood(id: vibe.id))),
            1
        )
        let journal = try LibraryMigration.loadJournal(from: libraryRoot)
        XCTAssertEqual(journal.phase, .complete)
        XCTAssertEqual(journal.migrationVersion, LibraryMigration.migrationVersion)
        XCTAssertEqual(journal.schemaVersion, LibraryMigration.schemaVersion)
    }
}
