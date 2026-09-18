import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Moodpaper

@MainActor
final class Phase6B2LegacySourceRetirementTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase6B2-\(UUID().uuidString)", isDirectory: true)
        suiteName = "HorizonTests.Phase6B2.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.testUnloadableLibraryRoot = nil
        LibraryMigration.environmentProvider = { [:] }
    }

    override func tearDown() {
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.testUnloadableLibraryRoot = nil
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        root = nil
        super.tearDown()
    }

    private func makeStore(at base: URL? = nil) -> MoodStore {
        MoodStore(baseURL: base ?? root, defaults: defaults)
    }

    private func writePNG(
        to url: URL,
        color: CGColor = CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 12, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func userWallpapersRoot(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("UserWallpapers", isDirectory: true)
    }

    private func makeArtBySlot() throws -> [String: URL] {
        var art: [String: URL] = [:]
        for (index, slot) in TimeSlot.allCases.enumerated() {
            let url = root.appendingPathComponent("starter-\(slot.slotID).png")
            let channel = CGFloat(index + 1) / CGFloat(TimeSlot.allCases.count)
            try writePNG(
                to: url,
                color: CGColor(red: channel, green: 0.3, blue: 1 - channel, alpha: 1)
            )
            art[slot.slotID] = url
        }
        return art
    }

    private func makeLegacyLibrary() async throws -> URL {
        let legacy = root.appendingPathComponent("legacy-library", isDirectory: true)
        let moodsRoot = legacy.appendingPathComponent("Moods", isDirectory: true)
        try FileManager.default.createDirectory(at: moodsRoot, withIntermediateDirectories: true)
        let mood = Mood(
            id: "mood-legacy",
            name: "Optimistic",
            createdAt: Date(),
            updatedAt: Date(),
            wallpapersPerDay: 8
        )
        try JSONEncoder().encode([mood]).write(to: moodsRoot.appendingPathComponent("moods.json"))
        let dawn = moodsRoot.appendingPathComponent("mood-legacy/Dawn", isDirectory: true)
        try writePNG(to: dawn.appendingPathComponent("lake.png"))
        return legacy
    }

    // MARK: - Init must not mint UserWallpapers/

    func testStoreInitializationDoesNotCreateUserWallpapersDirectory() {
        _ = makeStore()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: userWallpapersRoot(in: root).path),
            "MoodStore must not create UserWallpapers/ on a disposable root"
        )
    }

    func testPreservedUserWallpapersDetectionDoesNotCreateTheFolder() {
        let store = makeStore()
        XCTAssertTrue(store.preservedUserWallpapers().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userWallpapersRoot(in: root).path))
    }

    // MARK: - Existing UserWallpapers data

    func testExistingNonEmptyUserWallpapersArePreservedAndImportable() async throws {
        let leftover = userWallpapersRoot(in: root)
            .appendingPathComponent("Morning", isDirectory: true)
            .appendingPathComponent("kept.png")
        try writePNG(to: leftover)
        let global = userWallpapersRoot(in: root)
            .appendingPathComponent("Global", isDirectory: true)
            .appendingPathComponent("pool.png")
        try writePNG(to: global, color: CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))

        let store = makeStore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: global.path))

        let preserved = store.preservedUserWallpapers()
        XCTAssertEqual(preserved.count, 2)

        try store.ensureCatalog()
        let mood = try XCTUnwrap(store.ensurePlayableVibe())
        let summary = try await store.importPreservedUserWallpapers(into: mood)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertTrue(store.usesCatalog)
        XCTAssertEqual(store.totalWallpaperCount(in: mood), 2)
        XCTAssertEqual(store.wallpapers(for: .morning, in: mood).count, 1)
        XCTAssertEqual(store.allDayWallpapers(in: mood).count, 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path), "source files must stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: global.path), "source files must stay")

        for asset in try XCTUnwrap(store.catalog?.assets) {
            XCTAssertFalse(asset.id.hasPrefix("/"), "asset identity must not be an absolute path")
            XCTAssertFalse(asset.relativePath.hasPrefix("/"))
            XCTAssertFalse(asset.relativePath.contains("UserWallpapers"))
        }
    }

    // MARK: - Onboarding

    func testLegacyOnboardingCreatesVisibleSlotFiles() async throws {
        LibraryMigration.testLiveLibraryRoot = root
        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        let art = try makeArtBySlot()
        let created = try await store.createStarterVibe(named: "Daybreak", artBySlotID: art)
        let mood = try XCTUnwrap(created)
        XCTAssertEqual(mood.name, "Daybreak")
        XCTAssertFalse(store.usesCatalog)
        XCTAssertEqual(store.totalWallpaperCount(in: mood), TimeSlot.allCases.count)
        for slot in TimeSlot.allCases {
            XCTAssertFalse(
                store.wallpapers(for: slot, in: mood).isEmpty,
                "\(slot.rawValue) should have a visible wallpaper"
            )
        }
    }

    func testCatalogOnboardingCreatesVisibleMemberships() async throws {
        let store = makeStore()
        try store.ensureCatalog()
        XCTAssertTrue(store.usesCatalog)
        let art = try makeArtBySlot()
        let created = try await store.createStarterVibe(named: "Daybreak", artBySlotID: art)
        let mood = try XCTUnwrap(created)
        XCTAssertEqual(store.catalog?.memberships(forMoodID: mood.id).count, TimeSlot.allCases.count)
        XCTAssertEqual(store.totalWallpaperCount(in: mood), TimeSlot.allCases.count)
        XCTAssertTrue(
            store.libraryItems(in: mood).allSatisfy { $0.assetID != nil },
            "Catalog onboarding must create visible memberships, not folder-only copies"
        )
        for item in store.libraryItems(in: mood) {
            XCTAssertFalse((item.assetID ?? "").hasPrefix("/"))
            XCTAssertTrue(item.url.path.contains("/Catalog/Assets/"))
        }
    }

    func testOnboardingRerunDoesNotCreateOrphanCatalogVibe() async throws {
        let store = makeStore()
        try store.ensureCatalog()
        let art = try makeArtBySlot()
        let firstCreated = try await store.createStarterVibe(named: "Daybreak", artBySlotID: art)
        let first = try XCTUnwrap(firstCreated)
        let secondName = VibeNaming.uniqueName("Daybreak", existing: store.moods.map(\.name))
        let secondCreated = try await store.createStarterVibe(named: secondName, artBySlotID: art)
        let second = try XCTUnwrap(secondCreated)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.totalWallpaperCount(in: first), TimeSlot.allCases.count)
        XCTAssertEqual(store.totalWallpaperCount(in: second), TimeSlot.allCases.count)
        XCTAssertFalse(store.moods.contains { store.totalWallpaperCount(in: $0) == 0 })
    }

    // MARK: - Legacy import after Catalog

    func testDirectImportLibraryIsBlockedWhenDestinationAlreadyUsesCatalog() async throws {
        let destinationStore = makeStore()
        try destinationStore.ensureCatalog()
        let legacy = try await makeLegacyLibrary()

        XCTAssertThrowsError(
            try LegacyLibraryMigration.importLibrary(from: legacy, into: root)
        ) { error in
            XCTAssertTrue(error is LegacyLibraryMigration.CatalogBackedDestinationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: userWallpapersRoot(in: root).path))
    }

    func testPostCatalogLegacyImportCreatesVisibleCatalogAssets() async throws {
        let destinationStore = makeStore()
        try destinationStore.ensureCatalog()

        let legacy = root.appendingPathComponent("legacy-library", isDirectory: true)
        let moodsRoot = legacy.appendingPathComponent("Moods", isDirectory: true)
        try FileManager.default.createDirectory(at: moodsRoot, withIntermediateDirectories: true)
        let mood = Mood(
            id: "mood-legacy",
            name: "Optimistic",
            createdAt: Date(),
            updatedAt: Date(),
            wallpapersPerDay: 8
        )
        try JSONEncoder().encode([mood]).write(to: moodsRoot.appendingPathComponent("moods.json"))
        try writePNG(to: moodsRoot.appendingPathComponent("mood-legacy/Dawn/lake.png"))

        let leftover = userWallpapersRoot(in: legacy)
            .appendingPathComponent("Global", isDirectory: true)
            .appendingPathComponent("old-pool.png")
        try writePNG(to: leftover, color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1))

        let summary = try await destinationStore.importLegacyLibrary(from: legacy)
        XCTAssertGreaterThanOrEqual(summary.moodCount, 1)
        XCTAssertGreaterThanOrEqual(summary.imageCount, 2)
        XCTAssertTrue(destinationStore.usesCatalog)

        let imported = try XCTUnwrap(destinationStore.moods.first { $0.name == "Optimistic" })
        XCTAssertGreaterThanOrEqual(destinationStore.totalWallpaperCount(in: imported), 2)
        XCTAssertFalse(destinationStore.libraryItems(in: imported).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: userWallpapersRoot(in: root).appendingPathComponent("Global/old-pool.png").path
            ),
            "must not copy UserWallpapers/ into the destination as a second source of truth"
        )
        for asset in try XCTUnwrap(destinationStore.catalog?.assets) {
            XCTAssertFalse(asset.id.hasPrefix("/"))
        }
    }

    func testImportLibraryNoLongerCopiesUserWallpapersTree() throws {
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        let moodsRoot = legacy.appendingPathComponent("Moods", isDirectory: true)
        try FileManager.default.createDirectory(at: moodsRoot, withIntermediateDirectories: true)
        let mood = Mood(id: "mood-a", name: "Optimistic", createdAt: Date(), updatedAt: Date(), wallpapersPerDay: 8)
        try JSONEncoder().encode([mood]).write(to: moodsRoot.appendingPathComponent("moods.json"))
        let allDay = moodsRoot.appendingPathComponent("mood-a/AllDay", isDirectory: true)
        try FileManager.default.createDirectory(at: allDay, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: allDay.appendingPathComponent("one.jpg"))

        let leftover = userWallpapersRoot(in: legacy)
            .appendingPathComponent("Global", isDirectory: true)
            .appendingPathComponent("kept.jpg")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: leftover)

        let summary = try LegacyLibraryMigration.importLibrary(from: legacy, into: dest)
        XCTAssertEqual(summary.moodCount, 1)
        XCTAssertEqual(summary.imageCount, 1)
        XCTAssertEqual(summary.preservedUserWallpaperCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: userWallpapersRoot(in: dest).path))
    }

    // MARK: - Source of truth

    func testProductionSourceNoLongerOwnsUserWallpaperManager() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let production = repoRoot.appendingPathComponent("Moodpaper")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: production.appendingPathComponent("UserWallpaperManager.swift").path)
        )

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: production,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("UserWallpaperManager") {
                hits.append(url.lastPathComponent)
            }
            XCTAssertFalse(
                source.contains("enum WallpaperSource:"),
                "\(url.lastPathComponent) still declares WallpaperSource"
            )
            XCTAssertFalse(
                source.contains("struct TimeSlotConfig"),
                "\(url.lastPathComponent) still declares TimeSlotConfig"
            )
            XCTAssertFalse(
                source.contains("UserWallpaperManager.shared"),
                "\(url.lastPathComponent) still uses UserWallpaperManager.shared"
            )
        }
        XCTAssertTrue(hits.isEmpty, "production still mentions UserWallpaperManager: \(hits)")
    }
}
