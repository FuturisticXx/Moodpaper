import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Moodpaper

@MainActor
final class MoodStoreTests: XCTestCase {
    private var baseURL: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodStoreTests-\(UUID().uuidString)")
        suiteName = "HorizonTests.MoodStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { [:] }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseURL)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        baseURL = nil
        super.tearDown()
    }

    private func makeStore() -> MoodStore {
        MoodStore(baseURL: baseURL, defaults: defaults)
    }

    private func writeTestImage(to url: URL, color: CGColor = CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: First run

    func testFirstRunStartsWithoutAnyVibes() {
        let store = makeStore()
        XCTAssertTrue(store.moods.isEmpty)
        XCTAssertNil(store.activeMoodID)
        XCTAssertNil(store.activeMood)
    }

    // MARK: Create

    func testCreateAddsMoodAndFolder() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "  Work Week  "))
        XCTAssertEqual(mood.name, "Work Week")
        XCTAssertTrue(store.moods.contains(mood))
        let folder = baseURL
            .appendingPathComponent("Moods")
            .appendingPathComponent(mood.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCreatingFirstVibeActivatesIt() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Optimistic"))

        XCTAssertEqual(store.activeMoodID, vibe.id)
        XCTAssertEqual(store.activeMood?.name, "Optimistic")
    }

    func testCreateAllowsUnnamedVibe() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "   "))
        XCTAssertTrue(vibe.isUnnamed)
        XCTAssertEqual(vibe.displayName, "My Wallpapers")
        XCTAssertEqual(store.activeMoodID, vibe.id)
    }

    func testEnsurePlayableVibeCreatesUnnamedDefaultWhenCatalogIsEmpty() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.ensurePlayableVibe())
        XCTAssertTrue(vibe.isUnnamed)
        XCTAssertEqual(store.moods.count, 1)
        XCTAssertEqual(store.activeMoodID, vibe.id)
    }

    func testNewVibesInheritSettingsDefaultCadenceNotSiblingCadence() throws {
        // Set the Settings default before creating the store
        defaults.set(12.0, forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "Calm"))
        // The new Vibe should inherit the Settings default (12)
        XCTAssertEqual(first.wallpapersPerDay, 12, "First Vibe should inherit Settings default of 12")
        // Change the first Vibe's cadence
        store.setWallpapersPerDay(4, for: first)
        // Fetch the updated first mood from the store since Mood is a value type
        let updatedFirst = try XCTUnwrap(store.mood(id: first.id))
        // Create a second Vibe - it should still inherit the Settings default (12), not the sibling's value (4)
        let second = try XCTUnwrap(store.create(name: "Bright"))
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: updatedFirst), 4, "First Vibe effective cadence should be 4")
        XCTAssertEqual(second.wallpapersPerDay, 12, "Second Vibe should inherit Settings default of 12, not sibling's 4")
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: second), 12, "Second Vibe effective cadence should be 12")
    }

    func testLegacyMoodsWithoutCadenceCopyTheCurrentGlobalSetting() throws {
        defaults.set(15.0, forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        let original = makeStore()
        let mood = try XCTUnwrap(original.create(name: "Legacy"))
        let metadata = baseURL.appendingPathComponent("Moods").appendingPathComponent("moods.json")
        let data = try Data(contentsOf: metadata)
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        catalog = catalog.map { entry in
            var copy = entry
            copy.removeValue(forKey: "wallpapersPerDay")
            return copy
        }
        try JSONSerialization.data(withJSONObject: catalog).write(to: metadata)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.mood(id: mood.id)?.wallpapersPerDay, 15)
    }

    func testLegacyMoodsWithoutCadenceUseEightWhenGlobalWasNeverSet() throws {
        let original = makeStore()
        let mood = try XCTUnwrap(original.create(name: "Legacy"))
        let metadata = baseURL.appendingPathComponent("Moods").appendingPathComponent("moods.json")
        let data = try Data(contentsOf: metadata)
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        catalog = catalog.map { entry in
            var copy = entry
            copy.removeValue(forKey: "wallpapersPerDay")
            return copy
        }
        try JSONSerialization.data(withJSONObject: catalog).write(to: metadata)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.mood(id: mood.id)?.wallpapersPerDay, 8)
    }

    func testDuplicateCopiesCadence() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Original"))
        store.setWallpapersPerDay(6, for: mood)
        // Fetch the updated mood from the store since Mood is a value type
        let updatedMood = try XCTUnwrap(store.mood(id: mood.id))
        XCTAssertEqual(updatedMood.wallpapersPerDay, 6, "Source mood should have cadence 6")
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: updatedMood), 6, "Source effective cadence should be 6")
        let copy = try XCTUnwrap(store.duplicate(updatedMood))
        XCTAssertEqual(copy.wallpapersPerDay, 6, "Copy should have source's cadence 6")
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: copy), 6, "Copy effective cadence should be 6")
    }

    // MARK: Rename

    func testRenamePersistsAcrossReload() throws {
        var store: MoodStore? = makeStore()
        let mood = try XCTUnwrap(store?.create(name: "Old Name"))
        store?.rename(mood, to: "New Name")

        store = makeStore()
        XCTAssertEqual(store?.mood(id: mood.id)?.name, "New Name")
    }

    // MARK: Duplicate

    func testDuplicateCopiesSlotImages() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Original"))
        let folder = store.folderURL(for: .morning, in: mood)
        let file = folder.appendingPathComponent("test-image.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)

        let copy = try XCTUnwrap(store.duplicate(mood))
        XCTAssertEqual(copy.name, "Original Copy")
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: copy), 1)
        // The copy is independent of the original's files.
        try store.removeWallpaper(store.wallpapers(for: .morning, in: mood)[0], from: mood)
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: copy), 1)
    }

    // MARK: Delete

    func testDeleteRemovesFilesAndFallsBackToRemainingMood() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "First"))
        let second = try XCTUnwrap(store.create(name: "Second"))
        store.activate(second)
        XCTAssertEqual(store.activeMoodID, second.id)

        let folder = baseURL
            .appendingPathComponent("Moods")
            .appendingPathComponent(second.id)
        store.delete(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(store.moods.contains { $0.id == second.id })
        XCTAssertEqual(store.activeMoodID, first.id)
        XCTAssertEqual(store.activeMood?.name, "First")
    }

    func testDeletingLastVibeReturnsToEmptyState() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Optimistic"))
        store.delete(vibe)

        XCTAssertTrue(store.moods.isEmpty)
        XCTAssertNil(store.activeMoodID)
        XCTAssertNil(store.activeMood)
    }

    // MARK: Switch

    func testActivateSwitchesAndPersistsAcrossReload() throws {
        var store: MoodStore? = makeStore()
        let cozy = try XCTUnwrap(store?.create(name: "Cozy Weekend"))
        store?.activate(cozy)

        store = makeStore()
        XCTAssertEqual(store?.activeMoodID, cozy.id)
        XCTAssertEqual(store?.activeMood?.name, "Cozy Weekend")
    }

    func testActivateIgnoresUnknownMood() {
        let store = makeStore()
        let originalActive = store.activeMoodID
        let ghost = Mood(id: "ghost", name: "Ghost", createdAt: Date(), updatedAt: Date())
        store.activate(ghost)
        XCTAssertEqual(store.activeMoodID, originalActive)
    }

    // MARK: Persistence round-trip

    func testMoodListRoundTripsThroughMoodsJSON() throws {
        var store: MoodStore? = makeStore()
        let a = try XCTUnwrap(store?.create(name: "Alpha"))
        let b = try XCTUnwrap(store?.create(name: "Beta"))

        store = makeStore()
        let names = store?.moods.map(\.name)
        XCTAssertEqual(names, ["Alpha", "Beta"])
        XCTAssertEqual(store?.mood(id: a.id)?.id, a.id)
        XCTAssertEqual(store?.mood(id: b.id)?.id, b.id)
    }

    func testStaleActiveIDInDefaultsFallsBackToFirstMood() {
        _ = makeStore().create(name: "Optimistic")
        defaults.set("no-such-mood", forKey: MoodStore.activeMoodIDKey)
        let store = makeStore()
        XCTAssertEqual(store.activeMoodID, store.moods.first?.id)
    }

    // MARK: Import

    func testImportCopiesNormalizedJPEGIntoSlotFolder() async throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))

        // Render a tiny real image to import.
        let sourceURL = baseURL.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            sourceURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let summary = try await store.importWallpapers(from: [sourceURL], to: .evening, in: mood)

        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        let imported = store.wallpapers(for: .evening, in: mood)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.pathExtension, "jpg")
        // Copy-on-import: deleting the source must not affect the mood.
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(store.wallpaperCount(for: .evening, in: mood), 1)
    }

    /// A slot import must survive one bad file the same way the All Day path
    /// already does. Before Stage 0 the slot importer threw on the first
    /// undecodable image and abandoned every remaining file silently.
    func testSlotImportKeepsSuccessfulImagesWhenAnotherImageFails() async throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let sourceFolder = baseURL.appendingPathComponent("Mixed Slot Wallpapers")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let good = sourceFolder.appendingPathComponent("good.png")
        let broken = sourceFolder.appendingPathComponent("broken.jpg")
        try writeTestImage(to: good)
        try Data("not an image".utf8).write(to: broken)

        let summary = try await store.importWallpapers(from: [good, broken], to: .morning, in: mood)

        XCTAssertEqual(summary.discoveredCount, 2)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: mood), 1)
    }

    /// Slot import shares the All Day walker, so dropping a folder onto a time
    /// slot now works instead of being silently ignored.
    func testSlotImportWalksFoldersRecursively() async throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let sourceFolder = baseURL.appendingPathComponent("Slot Folder")
        let nestedFolder = sourceFolder.appendingPathComponent("Favorites")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try writeTestImage(to: sourceFolder.appendingPathComponent("lake.png"))
        try writeTestImage(
            to: nestedFolder.appendingPathComponent("forest.png"),
            color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)
        )
        try Data("notes".utf8).write(to: sourceFolder.appendingPathComponent("notes.txt"))

        let summary = try await store.importWallpapers(from: [sourceFolder], to: .dusk, in: mood)

        XCTAssertEqual(summary.discoveredCount, 2)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(store.wallpaperCount(for: .dusk, in: mood), 2)
    }

    func testEffectiveWallpapersFallsBackToAllDayPoolForEmptySlot() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let allDayFolder = store.allDayFolderURL(in: mood)
        let allDayImage = allDayFolder.appendingPathComponent("shared.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: allDayImage)

        XCTAssertEqual(
            store.effectiveWallpapers(for: .morning, in: mood).map(\.lastPathComponent),
            [allDayImage.lastPathComponent]
        )
    }

    func testEffectiveWallpapersPrefersSlotSpecificPoolOverAllDayPool() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let allDayImage = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: allDayImage)
        let morningImage = store.folderURL(for: .morning, in: mood).appendingPathComponent("morning.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: morningImage)

        XCTAssertEqual(
            store.effectiveWallpapers(for: .morning, in: mood).map(\.lastPathComponent),
            [morningImage.lastPathComponent]
        )
    }

    func testImportAllDayFolderRecursivelyImportsImagesAndIgnoresOtherFiles() async throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let sourceFolder = baseURL.appendingPathComponent("Wallpaper Folder")
        let nestedFolder = sourceFolder.appendingPathComponent("Favorites")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try writeTestImage(to: sourceFolder.appendingPathComponent("lake.png"))
        try writeTestImage(
            to: nestedFolder.appendingPathComponent("forest.png"),
            color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)
        )
        try Data("notes".utf8).write(to: sourceFolder.appendingPathComponent("notes.txt"))

        let summary = try await store.importAllDayWallpapers(from: [sourceFolder], in: mood)

        XCTAssertEqual(summary.discoveredCount, 2)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(store.allDayWallpapers(in: mood).count, 2)
        XCTAssertEqual(store.totalWallpaperCount(in: mood), 2)
    }

    func testImportAllDayKeepsSuccessfulImagesWhenAnotherImageFails() async throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let sourceFolder = baseURL.appendingPathComponent("Mixed Wallpapers")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try writeTestImage(to: sourceFolder.appendingPathComponent("good.png"))
        try Data("not an image".utf8).write(to: sourceFolder.appendingPathComponent("broken.jpg"))

        let summary = try await store.importAllDayWallpapers(from: [sourceFolder], in: mood)

        XCTAssertEqual(summary.discoveredCount, 2)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(store.allDayWallpapers(in: mood).count, 1)
    }

    func testLibraryItemsIncludeFallbackPoolAndSlotFiles() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)
        let morning = store.folderURL(for: .morning, in: mood).appendingPathComponent("morning.jpg")
        try writeTestImage(to: morning)

        let items = store.libraryItems(in: mood)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            items.first { $0.url.lastPathComponent == "shared.jpg" }?.placement,
            .throughoutTheDay
        )
        XCTAssertEqual(
            items.first { $0.url.lastPathComponent == "morning.jpg" }?.placement,
            .during(.morning)
        )
    }

    func testSetPlacementMovesFallbackWallpaperIntoATimeSlot() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)

        try store.setWallpaperPlacement(.during(.dawn), for: throughout, in: mood)

        XCTAssertTrue(store.allDayWallpapers(in: mood).isEmpty)
        XCTAssertEqual(store.wallpaperCount(for: .dawn, in: mood), 1)
        XCTAssertEqual(
            store.libraryItems(in: mood).first?.placement,
            .during(.dawn)
        )
    }

    func testSetPlacementMovesSlotWallpaperBackToThroughoutTheDay() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let morning = store.folderURL(for: .morning, in: mood).appendingPathComponent("morning.jpg")
        try writeTestImage(to: morning)

        try store.setWallpaperPlacement(.throughoutTheDay, for: morning, in: mood)

        XCTAssertEqual(store.wallpaperCount(for: .morning, in: mood), 0)
        XCTAssertEqual(store.allDayWallpapers(in: mood).count, 1)
        XCTAssertEqual(store.libraryItems(in: mood).first?.placement, .throughoutTheDay)
    }

    func testRemoveWallpaperDeletesFallbackPoolFiles() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)

        XCTAssertNoThrow(try store.removeWallpaper(throughout, from: mood))
        XCTAssertTrue(store.allDayWallpapers(in: mood).isEmpty)
        XCTAssertTrue(store.libraryItems(in: mood).isEmpty)
    }

    // MARK: Remove

    /// The delete-failure banner can only appear if the store actually
    /// propagates the error. Deterministic and hermetic: the file is removed
    /// inside this test's own scratch directory, never a real container.
    func testRemoveWallpaperThrowsWhenTheFileIsAlreadyGone() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let wallpaper = store.folderURL(for: .morning, in: mood)
            .appendingPathComponent("gone.jpg")
        try writeTestImage(to: wallpaper)
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: mood), 1)

        // Simulates the wallpaper disappearing underneath the Manage sheet —
        // deleted in Finder, an unmounted volume, a permissions change.
        try FileManager.default.removeItem(at: wallpaper)

        XCTAssertThrowsError(try store.removeWallpaper(wallpaper, from: mood))
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: mood), 0)
    }

    func testRemoveWallpaperSucceedsForAPresentFile() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Test Vibe"))
        let wallpaper = store.folderURL(for: .morning, in: mood)
            .appendingPathComponent("present.jpg")
        try writeTestImage(to: wallpaper)

        XCTAssertNoThrow(try store.removeWallpaper(wallpaper, from: mood))
        XCTAssertEqual(store.wallpaperCount(for: .morning, in: mood), 0)
    }

    // MARK: Mood switch refresh hook

    func testActivateFiresChangeHookExactlyOnce() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.create(name: "Optimistic"))
        let cozy = try XCTUnwrap(store.create(name: "Cozy"))
        var fired = 0
        store.onActiveMoodChange = { fired += 1 }

        store.activate(cozy)
        XCTAssertEqual(fired, 1)

        // Re-activating the already-active mood must not refresh.
        store.activate(cozy)
        XCTAssertEqual(fired, 1)
    }

    func testDeletingActiveMoodFiresChangeHookForFallback() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "First"))
        let second = try XCTUnwrap(store.create(name: "Second"))
        store.activate(second)
        var fired = 0
        store.onActiveMoodChange = { fired += 1 }

        store.delete(second)
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(store.activeMoodID, first.id)
    }

    func testDeletingInactiveMoodDoesNotFireChangeHook() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.create(name: "First"))
        let second = try XCTUnwrap(store.create(name: "Second"))
        XCTAssertEqual(store.activeMoodID, first.id)
        var fired = 0
        store.onActiveMoodChange = { fired += 1 }

        store.delete(second)
        XCTAssertEqual(fired, 0)
    }

    // MARK: Shape My Day assignments

    func testEmptyDetailedPeriodFallsBackToVibePhotos() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)

        XCTAssertTrue(store.wallpapers(for: .dawn, in: mood).isEmpty)
        XCTAssertEqual(
            store.effectiveWallpapers(for: .dawn, in: mood).map(\.lastPathComponent),
            ["shared.jpg"]
        )
        XCTAssertEqual(
            store.dayPartRepresentation(for: .morning, in: mood),
            .usingVibePhotos
        )
    }

    func testAssignedDetailedPeriodOverridesVibeFallback() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)
        let dawn = store.folderURL(for: .dawn, in: mood).appendingPathComponent("dawn-only.jpg")
        try writeTestImage(to: dawn)

        XCTAssertEqual(
            store.effectiveWallpapers(for: .dawn, in: mood).map(\.lastPathComponent),
            ["dawn-only.jpg"]
        )
        XCTAssertEqual(
            store.effectiveWallpapers(for: .sunrise, in: mood).map(\.lastPathComponent),
            ["shared.jpg"]
        )
    }

    func testFourGroupAssignmentWritesEveryMappedDetailedPeriodWithoutLeavingTheVibePool() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("lake.jpg")
        try writeTestImage(to: throughout)
        let cadence = store.effectiveWallpapersPerDay(for: mood)

        try store.assignWallpaper(throughout, to: .morning, in: mood)

        XCTAssertEqual(store.allDayWallpapers(in: mood).map(\.lastPathComponent), ["lake.jpg"])
        for slot in DayPartGroup.morning.slots {
            XCTAssertEqual(
                store.wallpapers(for: slot, in: mood).map(\.lastPathComponent),
                ["lake.jpg"]
            )
        }
        XCTAssertTrue(store.wallpapers(for: .midday, in: mood).isEmpty)
        XCTAssertEqual(
            store.dayPartRepresentation(for: .morning, in: mood),
            .assigned(filenames: ["lake.jpg"])
        )
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: mood), cadence)
    }

    func testRefiningOneDetailedPeriodLeavesTheOthersUntouched() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("lake.jpg")
        try writeTestImage(to: throughout)
        try store.assignWallpaper(throughout, to: .morning, in: mood)

        let dawnCopy = try XCTUnwrap(store.wallpapers(for: .dawn, in: mood).first)
        try store.removeWallpaperAssignment(dawnCopy, from: .dawn, in: mood)

        XCTAssertTrue(store.wallpapers(for: .dawn, in: mood).isEmpty)
        XCTAssertEqual(
            store.effectiveWallpapers(for: .dawn, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
        XCTAssertEqual(
            store.wallpapers(for: .sunrise, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
        XCTAssertEqual(
            store.wallpapers(for: .morning, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
        XCTAssertEqual(
            store.wallpapers(for: .deepNight, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
        XCTAssertEqual(store.dayPartRepresentation(for: .morning, in: mood), .mixed)
    }

    func testUnassigningAPeriodReturnsThatPeriodToFallback() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)
        try store.addWallpaperAssignment(throughout, to: .midday, in: mood)

        let middayCopy = try XCTUnwrap(store.wallpapers(for: .midday, in: mood).first)
        try store.removeWallpaperAssignment(middayCopy, from: .midday, in: mood)

        XCTAssertTrue(store.wallpapers(for: .midday, in: mood).isEmpty)
        XCTAssertEqual(
            store.effectiveWallpapers(for: .midday, in: mood).map(\.lastPathComponent),
            ["shared.jpg"]
        )
    }

    func testExistingDetailedAssignmentsAreUnchangedWhenInspectingTheFourGroupSummary() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Legacy"))
        let dawn = store.folderURL(for: .dawn, in: mood).appendingPathComponent("dawn.jpg")
        let sunrise = store.folderURL(for: .sunrise, in: mood).appendingPathComponent("sunrise.jpg")
        try writeTestImage(to: dawn)
        try writeTestImage(to: sunrise, color: CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        let before = try folderFingerprint(in: mood, store: store)

        XCTAssertEqual(store.dayPartRepresentation(for: .morning, in: mood), .mixed)

        let after = try folderFingerprint(in: mood, store: store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(store.wallpapers(for: .dawn, in: mood).map(\.lastPathComponent), ["dawn.jpg"])
        XCTAssertEqual(store.wallpapers(for: .sunrise, in: mood).map(\.lastPathComponent), ["sunrise.jpg"])
        XCTAssertTrue(store.wallpapers(for: .morning, in: mood).isEmpty)
        XCTAssertTrue(store.allDayWallpapers(in: mood).isEmpty)
    }

    func testUnassigningAFourGroupLeavesOtherGroupsIntact() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("lake.jpg")
        try writeTestImage(to: throughout)
        try store.assignWallpaper(throughout, to: .day, in: mood)
        try store.assignWallpaper(throughout, to: .evening, in: mood)

        try store.unassignWallpaper(throughout, from: .day, in: mood)

        XCTAssertEqual(store.allDayWallpapers(in: mood).map(\.lastPathComponent), ["lake.jpg"])
        XCTAssertTrue(store.wallpapers(for: .midday, in: mood).isEmpty)
        XCTAssertTrue(store.wallpapers(for: .afternoon, in: mood).isEmpty)
        XCTAssertEqual(
            store.wallpapers(for: .goldenHour, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
        XCTAssertEqual(
            store.effectiveWallpapers(for: .afternoon, in: mood).map(\.lastPathComponent),
            ["lake.jpg"]
        )
    }

    func testPlayThroughoutTheDayRemovesEveryTimeAssignmentForThatWallpaper() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("lake.jpg")
        try writeTestImage(to: throughout)
        try store.assignWallpaper(throughout, to: .morning, in: mood)
        try store.assignWallpaper(throughout, to: .night, in: mood)

        try store.playThroughoutTheDay(throughout, in: mood)

        XCTAssertEqual(store.allDayWallpapers(in: mood).map(\.lastPathComponent), ["lake.jpg"])
        for slot in TimeSlot.allCases {
            XCTAssertTrue(store.wallpapers(for: slot, in: mood).isEmpty)
        }
    }

    func testPlayThroughoutTheDayFromSlotCopyReusesPoolEntryAndIsIdempotent() throws {
        // The Wallpapers grid hands over the slot copy's URL, not the pool URL.
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("lake.jpg")
        try writeTestImage(to: throughout)
        try store.assignWallpaper(throughout, to: .morning, in: mood)
        let slotCopy = try XCTUnwrap(store.wallpapers(for: .dawn, in: mood).first)

        try store.playThroughoutTheDay(slotCopy, in: mood)
        try store.playThroughoutTheDay(throughout, in: mood)

        XCTAssertEqual(store.allDayWallpapers(in: mood).map(\.lastPathComponent), ["lake.jpg"])
        for slot in TimeSlot.allCases {
            XCTAssertTrue(store.wallpapers(for: slot, in: mood).isEmpty)
        }
    }

    func testSkipPeriodStateIsIndependentOfWallpaperAssignments() throws {
        let store = makeStore()
        let mood = try XCTUnwrap(store.create(name: "Calm"))
        let throughout = store.allDayFolderURL(in: mood).appendingPathComponent("shared.jpg")
        try writeTestImage(to: throughout)
        try store.assignWallpaper(throughout, to: .night, in: mood)

        HorizonScheduleDefaults.setSlotEnabled(false, slotID: TimeSlot.evening.slotID, defaults: defaults)
        XCTAssertFalse(HorizonScheduleDefaults.isSlotEnabled(TimeSlot.evening.slotID, defaults: defaults))
        XCTAssertEqual(
            store.wallpapers(for: .evening, in: mood).map(\.lastPathComponent),
            ["shared.jpg"]
        )
        HorizonScheduleDefaults.setSlotEnabled(true, slotID: TimeSlot.evening.slotID, defaults: defaults)
        XCTAssertTrue(HorizonScheduleDefaults.isSlotEnabled(TimeSlot.evening.slotID, defaults: defaults))
        XCTAssertEqual(
            store.wallpapers(for: .evening, in: mood).map(\.lastPathComponent),
            ["shared.jpg"]
        )
    }

    private func folderFingerprint(in mood: Mood, store: MoodStore) throws -> [String: Int] {
        var fingerprint: [String: Int] = [:]
        let folders = [store.allDayFolderURL(in: mood)]
            + TimeSlot.allCases.map { store.folderURL(for: $0, in: mood) }
        for folder in folders {
            let files = (try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ))
            for file in files {
                let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                fingerprint[folder.lastPathComponent + "/" + file.lastPathComponent] = size
            }
        }
        return fingerprint
    }
}
