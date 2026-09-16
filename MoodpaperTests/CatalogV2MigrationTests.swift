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
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { [:] }
    }

    override func tearDown() {
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
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

    // MARK: - Canonical originalFilename selection

    func testPreferredOriginalFilenameIsDeterministicAcrossPathOrder() {
        let paths = [
            "/lib/Moods/v1/Morning/lake.png",
            "/lib/Moods/v1/AllDay/lake-copy.png",
            "/lib/Moods/v1/Sunrise/lake.png",
            "/lib/Moods/v1/AllDay/lake.png",
            "/lib/Moods/v2/AllDay/lake.png",
            "/lib/Moods/v1/DeepNight/lake.png",
        ]
        let expected = "lake.png"
        var seen = Set<String>()
        for _ in 0..<50 {
            let name = LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: paths.shuffled())
            seen.insert(name ?? "nil")
        }
        XCTAssertEqual(seen, [expected])
        XCTAssertEqual(LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: paths.reversed()), expected)
        XCTAssertNil(LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: []))
    }

    func testPreferredOriginalFilenameRules() {
        // 1. General source beats a period copy, even when longer and later in sort order.
        XCTAssertEqual(
            LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: [
                "/lib/Moods/v1/Morning/a.png",
                "/lib/Moods/v1/AllDay/zz-long-name.png",
            ]),
            "zz-long-name.png"
        )
        // 2. Among general sources, the shortest basename wins.
        XCTAssertEqual(
            LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: [
                "/lib/Moods/v1/AllDay/lake-copy.png",
                "/lib/Moods/v1/AllDay/lake.png",
            ]),
            "lake.png"
        )
        // 3. Equal length: lexical basename, then full path.
        XCTAssertEqual(
            LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: [
                "/lib/Moods/v1/AllDay/b.png",
                "/lib/Moods/v1/AllDay/a.png",
            ]),
            "a.png"
        )
        // Period-only sources still get a name.
        XCTAssertEqual(
            LibraryMigration.preferredOriginalFilename(forLegacySourcePaths: [
                "/lib/Moods/v1/Morning/sky.png",
                "/lib/Moods/v1/Dusk/sky.png",
            ]),
            "sky.png"
        )
    }

    /// The visible name follows the rule; identity, hash, memberships, and
    /// assignments are unaffected by which path sorts first.
    func testCollapsedDuplicateExposesGeneralShortestFilenameWithoutChangingIdentity() throws {
        let store = makeStore()
        let calm = try XCTUnwrap(store.create(name: "Calm"))
        let bold = try XCTUnwrap(store.create(name: "Bold"))
        let lake = store.allDayFolderURL(in: calm).appendingPathComponent("lake.png")
        let lakeCopy = store.allDayFolderURL(in: calm).appendingPathComponent("lake-copy.png")
        try writePNG(to: lake)
        try FileManager.default.copyItem(at: lake, to: lakeCopy)
        try store.assignWallpaper(lake, to: .morning, in: calm)
        let boldLake = store.allDayFolderURL(in: bold).appendingPathComponent("lake.png")
        try FileManager.default.createDirectory(at: boldLake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: lake, to: boldLake)
        let expectedHash = try WallpaperIdentity.sha256Hex(of: lake)
        let legacyFiles = LibraryMigration.legacyImageFiles(in: libraryRoot)
        // Within Calm's general pool, sorted legacy order puts lake-copy.png
        // before lake.png; the rule must not follow discovery order.
        let calmGeneral = legacyFiles.filter { $0.moodID == calm.id && $0.folderName == "AllDay" }
        XCTAssertEqual(calmGeneral.map(\.url.lastPathComponent), ["lake-copy.png", "lake.png"])

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let catalog = try LibraryMigration.loadCatalog(from: libraryRoot)
        let asset = try XCTUnwrap(catalog.assets.first)
        XCTAssertEqual(catalog.assets.count, 1)
        XCTAssertEqual(asset.originalFilename, "lake.png")
        XCTAssertEqual(asset.contentHash, expectedHash)
        XCTAssertEqual(asset.legacySourcePaths.count, legacyFiles.count)
        XCTAssertEqual(try WallpaperIdentity.sha256Hex(of: LibraryMigration.canonicalURL(for: asset, libraryRoot: libraryRoot)), expectedHash)

        // Identity comes from the journal mapping (content based), not the name.
        let journal = try LibraryMigration.loadJournal(from: libraryRoot)
        XCTAssertEqual(Set(journal.sourcePathToAssetID.values), [asset.id])

        let memberships = catalog.memberships.sorted { $0.moodID < $1.moodID }
        XCTAssertEqual(memberships.count, 2)
        let calmM = try XCTUnwrap(memberships.first { $0.moodID == calm.id })
        XCTAssertTrue(calmM.throughoutTheDay)
        XCTAssertEqual(Set(calmM.slotIDs), Set(DayPartGroup.morning.slots.map(\.rawValue)))
        let boldM = try XCTUnwrap(memberships.first { $0.moodID == bold.id })
        XCTAssertTrue(boldM.throughoutTheDay)
        XCTAssertEqual(boldM.slotIDs, [])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.dayPartRepresentation(for: .morning, in: calm), .assigned(filenames: ["lake.png"]))
    }

    func testFilenameCollisionWithoutMatchingMetadataStaysDistinct() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Ambiguous"))
        let a = store.allDayFolderURL(in: vibe).appendingPathComponent("photo.jpg")
        let b = store.folderURL(for: .evening, in: vibe).appendingPathComponent("photo.jpg")
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

    /// The live Application Support path is represented by a temp mock, never
    /// the real home directory. Test hosts must not publish catalog.json there.
    func testTestHostCannotPublishCatalogIntoLiveApplicationSupportPath() throws {
        let mockLive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockApplicationSupport-Moodpaper-\(UUID().uuidString)")
        LibraryMigration.testLiveLibraryRoot = mockLive
        let suite = "HorizonTests.LiveGuard.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        isolatedDefaults.removePersistentDomain(forName: suite)
        defer {
            LibraryMigration.testLiveLibraryRoot = nil
            isolatedDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: mockLive)
        }

        let vibeID = UUID().uuidString.lowercased()
        let allDay = mockLive
            .appendingPathComponent("Moods")
            .appendingPathComponent(vibeID)
            .appendingPathComponent(MoodStore.allDayFolderName)
        try writePNG(to: allDay.appendingPathComponent("library.png"))

        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: mockLive))
        XCTAssertTrue(LibraryMigration.needsMigration(libraryRoot: mockLive))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: mockLive)) { error in
            XCTAssertTrue(error is LibraryMigration.MigrationBlockedError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: WallpaperCatalogFile.catalogURL(in: mockLive).path
            )
        )

        let defaultPathStore = MoodStore(baseURL: nil, defaults: isolatedDefaults)
        XCTAssertFalse(defaultPathStore.usesCatalog)
        XCTAssertTrue(defaultPathStore.moods.isEmpty)
        XCTAssertThrowsError(try defaultPathStore.ensureCatalog())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: WallpaperCatalogFile.catalogURL(in: mockLive).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: allDay.appendingPathComponent("library.png").path),
            "legacy Moods files must remain"
        )
    }

    // MARK: - Migration authorization guard

    private static let authorizationKey = LibraryMigration.authorizationEnvironmentKey

    /// A temp folder standing in for the live Application Support root. It is
    /// registered as protected through `testLiveLibraryRoot`; the real home
    /// directory library is never written by these tests.
    private func makeProtectedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedMoodpaper-\(UUID().uuidString)")
        LibraryMigration.testLiveLibraryRoot = root
        try writePNG(to: root
            .appendingPathComponent("Moods")
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathComponent(MoodStore.allDayFolderName)
            .appendingPathComponent("library.png"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func authorize(_ root: URL) {
        LibraryMigration.environmentProvider = {
            [Self.authorizationKey: root.standardizedFileURL.path]
        }
    }

    private func snapshot(of root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[url.path] = try WallpaperIdentity.sha256Hex(of: url)
        }
        return result
    }

    private func assertNoMigrationArtifacts(at root: URL, file: StaticString = #filePath, line: UInt = #line) {
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.catalogURL(in: root).path), "catalog.json", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.journalURL(in: root).path), "journal.json", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.migrationRoot(in: root).path), "Migration/", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.backupsRoot(in: root).path), "Backups/", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.stagingRoot(in: root).path), "Staging/", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: WallpaperCatalogFile.assetsRoot(in: root).path), "Catalog/Assets", file: file, line: line)
    }

    /// 1. Protected root, no authorization: blocked. 7. Zero writes.
    func testProtectedRootWithoutAuthorizationBlocksMigrationAndWritesNothing() throws {
        let root = try makeProtectedRoot()
        let before = try snapshot(of: root)

        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(root))
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root)) { error in
            XCTAssertTrue(error is LibraryMigration.MigrationBlockedError)
            XCTAssertEqual(error.localizedDescription, LibraryMigration.blockedDiagnostic)
        }

        assertNoMigrationArtifacts(at: root)
        XCTAssertEqual(try snapshot(of: root), before, "a blocked run must not write anything")
    }

    /// 2. Protected root with a matching authorization: migration proceeds.
    func testProtectedRootWithMatchingAuthorizationMigrates() throws {
        let root = try makeProtectedRoot()
        authorize(root)

        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(root))
        XCTAssertFalse(LibraryMigration.isMigrationBlocked(for: root))
        let summary = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        XCTAssertEqual(summary.assetCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: WallpaperCatalogFile.catalogURL(in: root).path))
        XCTAssertEqual(try LibraryMigration.loadJournal(from: root).phase, .complete)
    }

    /// Authorization is scoped to one exact root; naming a different path
    /// authorizes nothing.
    func testAuthorizationForAnotherRootDoesNotUnblockProtectedRoot() throws {
        let root = try makeProtectedRoot()
        authorize(FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere"))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root))
        assertNoMigrationArtifacts(at: root)

        LibraryMigration.environmentProvider = { [Self.authorizationKey: ""] }
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
    }

    /// 3. Disposable root with explicit test configuration migrates without
    /// any authorization: it is not a protected root.
    func testDisposableRootMigratesWithoutAuthorization() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Disposable"))
        try writePNG(to: store.allDayFolderURL(in: vibe).appendingPathComponent("a.png"))

        XCTAssertFalse(LibraryMigration.isProtectedLibraryRoot(libraryRoot))
        XCTAssertFalse(LibraryMigration.isMigrationBlocked(for: libraryRoot))
        let summary = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        XCTAssertEqual(summary.assetCount, 1)
        XCTAssertTrue(makeStore().usesCatalog)
    }

    /// 4. Running inside XCTest grants nothing: the host is a test host, the
    /// real environment is ignored, and the protected root stays blocked.
    func testXCTestHostCannotBypassGuardAccidentally() throws {
        let root = try makeProtectedRoot()
        XCTAssertTrue(LibraryMigration.isRunningInTestHost)
        // The real process environment, whatever it holds, is not consulted
        // once a provider is injected; and the default provider does not name
        // a temp root either.
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root))
        assertNoMigrationArtifacts(at: root)

        // The real home-directory library is protected in this host too.
        let real = LibraryMigration.realUserLibraryRoot()
        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(real))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: real))
        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(LibraryMigration.defaultApplicationSupportLibraryRoot()))
    }

    /// 5. A stale catalog.json at a protected root is not adopted.
    func testStaleCatalogAtProtectedRootIsNotAdoptedWithoutAuthorization() throws {
        let root = try makeProtectedRoot()
        let stale = WallpaperCatalog.readyEmpty()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: WallpaperCatalogFile.catalogURL(in: root))
        let before = try snapshot(of: root)

        // The store resolves the protected root through the default-path
        // route, exactly as an ordinary launch would.
        let store = MoodStore(baseURL: nil, defaults: defaults)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertNil(store.catalog)
        XCTAssertThrowsError(try store.ensureCatalog()) { error in
            XCTAssertTrue(error is LibraryMigration.MigrationBlockedError)
        }
        XCTAssertEqual(try snapshot(of: root), before)
    }

    /// 6. No catalog.json at a protected root does not trigger a fresh
    /// catalog on import: the import lands on the legacy folder model.
    func testMissingCatalogAtProtectedRootDoesNotStartFreshMigration() throws {
        let root = try makeProtectedRoot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: WallpaperCatalogFile.catalogURL(in: root).path))
        XCTAssertTrue(LibraryMigration.needsMigration(libraryRoot: root))

        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root))
        let store = MoodStore(baseURL: nil, defaults: defaults)
        XCTAssertThrowsError(try store.ensureCatalog())
        assertNoMigrationArtifacts(at: root)
    }

    /// Imports on a blocked root use the legacy folder path instead of
    /// failing, so an unauthorized launch still works as before.
    func testImportOnBlockedRootUsesLegacyFoldersAndNeverCreatesCatalog() async throws {
        // A disposable root marked protected exercises the real import path.
        let root = libraryRoot!
        LibraryMigration.testLiveLibraryRoot = root
        let store = makeStore()
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        let vibe = try XCTUnwrap(store.create(name: "Legacy"))
        let source = root.appendingPathComponent("source.png")
        try writePNG(to: source)

        let summary = try await store.importAllDayWallpapers(from: [source], in: vibe)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertEqual(store.allDayWallpapers(in: vibe).count, 1)
        XCTAssertTrue(try XCTUnwrap(store.allDayWallpapers(in: vibe).first).path.contains("/Moods/\(vibe.id)/AllDay/"))
        assertNoMigrationArtifacts(at: root)
        XCTAssertThrowsError(try store.deleteWallpaperFromMoodpaper(source))
    }

    /// 8. Authorization never lands in UserDefaults and does not outlive the
    /// injected environment.
    func testAuthorizationIsNotPersistedAfterAuthorizedRun() throws {
        let root = try makeProtectedRoot()
        authorize(root)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        let store = MoodStore(baseURL: root, defaults: defaults)
        XCTAssertTrue(store.usesCatalog)

        XCTAssertNil(defaults.object(forKey: Self.authorizationKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.authorizationKey))
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(persisted.keys.contains { $0.localizedCaseInsensitiveContains("authoriz") })

        LibraryMigration.environmentProvider = { [:] }
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        // Only a second migration would need the authorization again; the
        // already-published catalog stays unreadable to an unauthorized
        // launch on the protected root.
        XCTAssertNil(MoodStore(baseURL: root, defaults: defaults).catalog)
    }

    /// Negative test against the user's actual library root. Read-only by
    /// construction: every call here is one the guard must refuse before its
    /// first write, and the test-host rule keeps `MoodStore` from loading the
    /// live root at all. Run it in an unsandboxed host (ENABLE_APP_SANDBOX=NO)
    /// so the default Application Support path resolves to the real one.
    func testRealUserLibraryRootIsBlockedWithoutAuthorization() throws {
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
        let real = LibraryMigration.realUserLibraryRoot()
        let processDefault = LibraryMigration.defaultApplicationSupportLibraryRoot()
        XCTAssertNil(
            ProcessInfo.processInfo.environment[Self.authorizationKey],
            "this negative test must run without any authorization in the environment"
        )

        XCTAssertTrue(real.path.hasSuffix("/Library/Application Support/Moodpaper"))
        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(real))
        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(processDefault))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: real))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: processDefault))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: real)) { error in
            XCTAssertTrue(error is LibraryMigration.MigrationBlockedError)
        }

        let store = MoodStore(baseURL: nil, defaults: defaults)
        XCTAssertEqual(store.storageRootURL.standardizedFileURL.path, processDefault.standardizedFileURL.path)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertNil(store.catalog)
        XCTAssertThrowsError(try store.ensureCatalog()) { error in
            XCTAssertTrue(error is LibraryMigration.MigrationBlockedError)
        }
        // The real root may legitimately hold a published catalog (Phase 6A
        // production migration); a blocked store must still ignore it. Zero
        // writes are proven by the external hash comparison around this run.
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: real))
    }

    // MARK: - Playback identifier boundary

    /// Migrates a two-Vibe library on the disposable root and returns the
    /// canonical asset path plus the legacy source paths for one wallpaper.
    private func migratedPlaybackFixture() throws -> (canonical: String, legacy: [String], activeVibe: Mood) {
        let store = makeStore()
        let calm = try XCTUnwrap(store.create(name: "Calm"))
        let bold = try XCTUnwrap(store.create(name: "Bold"))
        let calmLake = store.allDayFolderURL(in: calm).appendingPathComponent("lake.png")
        try writePNG(to: calmLake)
        let boldLake = store.allDayFolderURL(in: bold).appendingPathComponent("lake.png")
        try FileManager.default.createDirectory(at: boldLake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: calmLake, to: boldLake)
        store.activate(bold)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let catalog = try LibraryMigration.loadCatalog(from: libraryRoot)
        let asset = try XCTUnwrap(catalog.assets.first)
        XCTAssertEqual(catalog.assets.count, 1)
        let canonical = LibraryMigration.canonicalURL(for: asset, libraryRoot: libraryRoot).standardizedFileURL.path
        return (canonical, asset.legacySourcePaths.sorted(), bold)
    }

    private func catalogSnapshot() throws -> [String: String] {
        var out: [String: String] = [:]
        let catalogURL = WallpaperCatalogFile.catalogURL(in: libraryRoot)
        out["catalog.json"] = try WallpaperIdentity.sha256Hex(of: catalogURL)
        let assets = WallpaperCatalogFile.assetsRoot(in: libraryRoot)
        for file in try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil) {
            out[file.lastPathComponent] = try WallpaperIdentity.sha256Hex(of: file)
        }
        return out
    }

    /// 1. Adopted Catalog mode accepts a persisted Catalog/Assets identifier.
    func testAdoptedCatalogModeResolvesCatalogAssetIdentifier() throws {
        let fixture = try migratedPlaybackFixture()
        let store = makeStore()
        XCTAssertTrue(store.usesCatalog)
        XCTAssertTrue(store.isCatalogAssetPath(fixture.canonical))
        XCTAssertEqual(store.resolvePlaybackURL(forIdentifier: fixture.canonical)?.standardizedFileURL.path, fixture.canonical)
        // Unchanged semantics: an existing legacy path is used as-is, and one
        // that has gone away remaps to the canonical file.
        XCTAssertEqual(
            store.resolvePlaybackURL(forIdentifier: fixture.legacy[0])?.standardizedFileURL.path,
            fixture.legacy[0]
        )
        try FileManager.default.removeItem(atPath: fixture.legacy[0])
        XCTAssertEqual(
            store.resolvePlaybackURL(forIdentifier: fixture.legacy[0])?.standardizedFileURL.path,
            fixture.canonical
        )
    }

    /// 2 + 3. Blocked legacy mode never uses the asset path directly and
    /// remaps to the equivalent legacy wallpaper, preferring the active Vibe.
    func testBlockedLegacyModeRemapsCatalogAssetIdentifierToLegacyWallpaper() throws {
        let fixture = try migratedPlaybackFixture()
        LibraryMigration.testLiveLibraryRoot = libraryRoot
        let before = try catalogSnapshot()

        let store = makeStore()
        XCTAssertFalse(store.usesCatalog, "adoption is blocked without authorization")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.canonical))
        let resolved = try XCTUnwrap(store.resolvePlaybackURL(forIdentifier: fixture.canonical))
        XCTAssertNotEqual(resolved.standardizedFileURL.path, fixture.canonical)
        XCTAssertFalse(store.isCatalogAssetPath(resolved.path))
        XCTAssertTrue(fixture.legacy.contains(resolved.standardizedFileURL.path))
        XCTAssertTrue(
            resolved.path.contains("/Moods/\(fixture.activeVibe.id)/"),
            "remap prefers the active Vibe's copy"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))

        // 5. Nothing in the Catalog store was written or deleted.
        XCTAssertEqual(try catalogSnapshot(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.canonical))
        XCTAssertEqual(try LibraryMigration.loadJournal(from: libraryRoot).phase, .complete, "no migration reran")
    }

    /// 4. Without a legacy equivalent the stale identifier is ignored safely.
    func testBlockedLegacyModeIgnoresCatalogAssetIdentifierWithoutLegacyEquivalent() throws {
        let fixture = try migratedPlaybackFixture()
        LibraryMigration.testLiveLibraryRoot = libraryRoot
        for path in fixture.legacy {
            try FileManager.default.removeItem(atPath: path)
        }
        let before = try catalogSnapshot()

        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        XCTAssertNil(store.resolvePlaybackURL(forIdentifier: fixture.canonical))
        // An asset path the catalog does not know is ignored too.
        let unknown = WallpaperCatalogFile.assetsRoot(in: libraryRoot).appendingPathComponent("\(UUID().uuidString.lowercased()).png").path
        XCTAssertNil(store.resolvePlaybackURL(forIdentifier: unknown))
        XCTAssertEqual(try catalogSnapshot(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.canonical), "the asset is never deleted")

        // With no catalog.json at all, an asset-shaped path is ignored as well.
        let bare = makeStore()
        try FileManager.default.removeItem(at: WallpaperCatalogFile.catalogURL(in: libraryRoot))
        XCTAssertNil(bare.resolvePlaybackURL(forIdentifier: fixture.canonical))
    }

    /// 6. Ordinary identifiers behave as before in both modes.
    func testPlaybackResolutionKeepsExistingSemanticsForOrdinaryPaths() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Plain"))
        let legacyFile = store.allDayFolderURL(in: vibe).appendingPathComponent("plain.png")
        try writePNG(to: legacyFile)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertEqual(store.resolvePlaybackURL(forIdentifier: legacyFile.path)?.standardizedFileURL, legacyFile.standardizedFileURL)
        XCTAssertNil(store.resolvePlaybackURL(forIdentifier: libraryRoot.appendingPathComponent("missing.png").path))
        XCTAssertNil(store.resolvePlaybackURL(forIdentifier: "bundled-name"), "bundle names are not the store's concern")

        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: libraryRoot)
        let adopted = makeStore()
        XCTAssertTrue(adopted.usesCatalog)
        XCTAssertEqual(adopted.resolvePlaybackURL(forIdentifier: legacyFile.path)?.standardizedFileURL, legacyFile.standardizedFileURL)
        try FileManager.default.removeItem(at: legacyFile)
        let canonical = try XCTUnwrap(adopted.resolvePlaybackURL(forIdentifier: legacyFile.path))
        XCTAssertTrue(adopted.isCatalogAssetPath(canonical.path))
        XCTAssertNil(adopted.resolvePlaybackURL(forIdentifier: libraryRoot.appendingPathComponent("missing.png").path))
    }
}
