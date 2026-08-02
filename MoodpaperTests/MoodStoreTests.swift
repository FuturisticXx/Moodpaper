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

    func testCreateRejectsEmptyName() {
        let store = makeStore()
        XCTAssertNil(store.create(name: "   "))
        XCTAssertTrue(store.moods.isEmpty)
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

    func testImportCopiesNormalizedJPEGIntoSlotFolder() throws {
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

        try store.importWallpapers([sourceURL], to: .evening, in: mood)

        let imported = store.wallpapers(for: .evening, in: mood)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.pathExtension, "jpg")
        // Copy-on-import: deleting the source must not affect the mood.
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(store.wallpaperCount(for: .evening, in: mood), 1)
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
        try writeTestImage(to: nestedFolder.appendingPathComponent("forest.png"))
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
}
