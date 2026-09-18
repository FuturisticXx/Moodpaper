import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Moodpaper

/// Phase 6B.1: explicit Focus wallpapers are Catalog asset IDs. They outlive
/// Vibe edits and Vibe deletion, vanish with the asset, and never carry a
/// path. Everything else about Focus (the time slot) is unchanged.
@MainActor
final class FocusAssetSelectionTests: XCTestCase {
    private var libraryRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusAssetTests-\(UUID().uuidString)")
        suiteName = "HorizonTests.FocusAssets.\(UUID().uuidString)"
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

    /// A Catalog-backed store with one Vibe holding two distinct assets.
    private struct CatalogFixture {
        let store: MoodStore
        let vibe: Mood
        let skyID: String
        let lakeID: String
    }

    private func catalogFixture() async throws -> CatalogFixture {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Calm"))
        let sky = libraryRoot.appendingPathComponent("sky.png")
        let lake = libraryRoot.appendingPathComponent("lake.png")
        try writePNG(to: sky)
        try writePNG(to: lake, color: CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        let summary = try await store.importAllDayWallpapers(from: [sky, lake], in: vibe)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.importedAssetIDs.count, 2)
        XCTAssertTrue(store.usesCatalog)
        let assets = store.focusSelectableAssets()
        let skyID = try XCTUnwrap(assets.first { $0.originalFilename == "sky.png" }?.id)
        let lakeID = try XCTUnwrap(assets.first { $0.originalFilename == "lake.png" }?.id)
        return CatalogFixture(store: store, vibe: vibe, skyID: skyID, lakeID: lakeID)
    }

    // MARK: 1. Valid IDs resolve to canonical Catalog files

    func testValidFocusAssetIDsResolveToCanonicalCatalogURLs() async throws {
        let fixture = try await catalogFixture()
        FocusAssetSelection.setAssetIDs([fixture.skyID, fixture.lakeID], defaults: defaults)

        let urls = fixture.store.focusCandidateURLs(assetIDs: FocusAssetSelection.assetIDs(defaults: defaults))
        XCTAssertEqual(urls.count, 2)
        for url in urls {
            XCTAssertTrue(fixture.store.isCatalogAssetPath(url.path), "\(url.path) is not a Catalog asset")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(
            WallpaperManager.focusCandidates(explicitAssetURLs: urls, fallbackSlot: "deep-night"),
            .explicitAssets(urls)
        )
    }

    // MARK: 2. Empty set falls back to the Focus slot

    func testEmptySelectionFallsBackToFocusSlot() async throws {
        let fixture = try await catalogFixture()
        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), [])
        let urls = fixture.store.focusCandidateURLs(assetIDs: [])
        XCTAssertEqual(urls, [])
        XCTAssertEqual(
            WallpaperManager.focusCandidates(explicitAssetURLs: urls, fallbackSlot: "morning"),
            .slot("morning")
        )
    }

    // MARK: 3. Legacy and blocked stores always fall back

    func testLegacyStoreNeverOffersExplicitFocusAssets() throws {
        let store = makeStore()
        let vibe = try XCTUnwrap(store.create(name: "Walks"))
        try writePNG(to: store.allDayFolderURL(in: vibe).appendingPathComponent("lake.png"))
        XCTAssertFalse(store.usesCatalog)
        FocusAssetSelection.setAssetIDs(["any-id"], defaults: defaults)

        XCTAssertEqual(store.focusSelectableAssets(), [])
        XCTAssertNil(store.canonicalURL(forAssetID: "any-id"))
        XCTAssertEqual(store.focusCandidateURLs(assetIDs: ["any-id"]), [])
        XCTAssertEqual(
            WallpaperManager.focusCandidates(explicitAssetURLs: [], fallbackSlot: "dusk"),
            .slot("dusk")
        )
    }

    func testBlockedProtectedRootWithPublishedCatalogStillFallsBack() async throws {
        // Build a real catalog on an unprotected root, then reopen it as a
        // protected root without authorization: the store stays legacy and
        // Focus must not read Catalog assets through the back door.
        let fixture = try await catalogFixture()
        LibraryMigration.testLiveLibraryRoot = libraryRoot
        let blocked = makeStore()
        XCTAssertFalse(blocked.usesCatalog)
        XCTAssertTrue(blocked.needsLibraryUpdate)

        XCTAssertEqual(blocked.focusSelectableAssets(), [])
        XCTAssertEqual(blocked.focusCandidateURLs(assetIDs: [fixture.skyID, fixture.lakeID]), [])
    }

    // MARK: 4. Removing from a Vibe keeps the Focus choice

    func testRemovingAssetFromVibeKeepsFocusSelection() async throws {
        let fixture = try await catalogFixture()
        FocusAssetSelection.setAssetIDs([fixture.skyID], defaults: defaults)
        let skyURL = try XCTUnwrap(fixture.store.canonicalURL(forAssetID: fixture.skyID))

        try fixture.store.removeWallpaper(skyURL, from: fixture.vibe)
        XCTAssertEqual(fixture.store.allDayWallpapers(in: fixture.vibe).count, 1)
        XCTAssertTrue(fixture.store.catalog?.memberships.contains { $0.assetID == fixture.skyID } == false)

        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), [fixture.skyID])
        XCTAssertEqual(fixture.store.focusCandidateURLs(assetIDs: [fixture.skyID]), [skyURL])
        XCTAssertTrue(fixture.store.focusSelectableAssets().contains { $0.id == fixture.skyID })
    }

    // MARK: 5. Deleting a Vibe keeps the Focus choice

    func testDeletingVibeKeepsFocusAssetIDs() async throws {
        let fixture = try await catalogFixture()
        FocusAssetSelection.setAssetIDs([fixture.skyID, fixture.lakeID], defaults: defaults)

        fixture.store.delete(fixture.vibe)
        XCTAssertTrue(fixture.store.moods.isEmpty)

        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults).count, 2)
        XCTAssertEqual(fixture.store.focusCandidateURLs(assetIDs: [fixture.skyID, fixture.lakeID]).count, 2)
    }

    // MARK: 6. Deleting from Moodpaper prunes the reference

    func testDeletingAssetFromMoodpaperRemovesFocusReference() async throws {
        let fixture = try await catalogFixture()
        FocusAssetSelection.setAssetIDs([fixture.skyID, fixture.lakeID], defaults: defaults)
        let skyURL = try XCTUnwrap(fixture.store.canonicalURL(forAssetID: fixture.skyID))

        try fixture.store.deleteWallpaperFromMoodpaper(skyURL)

        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), [fixture.lakeID])
        XCTAssertNil(fixture.store.canonicalURL(forAssetID: fixture.skyID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skyURL.path))
    }

    // MARK: 7. All-invalid IDs collapse to the slot

    func testAllInvalidFocusIDsCollapseToSlotFallback() async throws {
        let fixture = try await catalogFixture()
        // Unknown ID, and a known ID whose file is gone.
        let lakeURL = try XCTUnwrap(fixture.store.canonicalURL(forAssetID: fixture.lakeID))
        try FileManager.default.removeItem(at: lakeURL)
        FocusAssetSelection.setAssetIDs(["missing-id", fixture.lakeID], defaults: defaults)

        let urls = fixture.store.focusCandidateURLs(assetIDs: FocusAssetSelection.assetIDs(defaults: defaults))
        XCTAssertEqual(urls, [])
        XCTAssertEqual(
            WallpaperManager.focusCandidates(explicitAssetURLs: urls, fallbackSlot: "evening"),
            .slot("evening")
        )
    }

    // MARK: 8. Never a path, always deterministic

    func testPersistedSelectionIsSortedUniqueAssetIDsAndNeverAPath() throws {
        FocusAssetSelection.setAssetIDs(
            ["b-id", "/Users/someone/Pictures/lake.jpg", "a-id", "b-id", "", "Catalog/Assets/x.jpg"],
            defaults: defaults
        )
        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), ["a-id", "b-id"])

        let raw = try XCTUnwrap(defaults.data(forKey: FocusAssetSelection.defaultsKey))
        let decoded = try JSONDecoder().decode([String].self, from: raw)
        XCTAssertEqual(decoded, ["a-id", "b-id"])
        XCTAssertFalse(decoded.contains { $0.contains("/") })

        FocusAssetSelection.toggle("a-id", defaults: defaults)
        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), ["b-id"])
        FocusAssetSelection.remove("b-id", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: FocusAssetSelection.defaultsKey), "empty set clears the key")
    }

    // MARK: 9. Browse is a normal Catalog import

    func testBrowseImportProducesOrdinaryCatalogAssetAndMembership() async throws {
        let fixture = try await catalogFixture()
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: libraryRoot.path)
            .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }
        let extra = libraryRoot.appendingPathComponent("desk.png")
        try writePNG(to: extra, color: CGColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1))

        // The picker's Browse path: ordinary All Day import, then mark the IDs.
        let summary = try await fixture.store.importAllDayWallpapers(from: [extra], in: fixture.vibe)
        for id in summary.importedAssetIDs {
            FocusAssetSelection.add(id, defaults: defaults)
        }
        let deskID = try XCTUnwrap(summary.importedAssetIDs.first)

        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), [deskID])
        XCTAssertNotNil(fixture.store.catalog?.asset(id: deskID))
        XCTAssertTrue(fixture.store.catalog?.memberships.contains {
            $0.assetID == deskID && $0.moodID == fixture.vibe.id && $0.throughoutTheDay
        } == true)
        XCTAssertEqual(fixture.store.allDayWallpapers(in: fixture.vibe).count, 3)

        // Exactly one new file, and it is the canonical asset: no Focus copy.
        let filesAfter = try FileManager.default.subpathsOfDirectory(atPath: libraryRoot.path)
            .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }
        let added = Set(filesAfter).subtracting(filesBefore).subtracting(["desk.png"])
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("Catalog/Assets/") }, "\(added)")
        XCTAssertFalse(filesAfter.contains { $0.hasPrefix("UserWallpapers/") })
    }

    // MARK: 10. One resolution for every Focus consumer

    func testDashboardPreviewAndMeetingPlaybackShareFocusCandidateResolution() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("Moodpaper/WallpaperManager.swift"), encoding: .utf8)
        let dashboard = try String(contentsOf: root.appendingPathComponent("Moodpaper/DashboardView.swift"), encoding: .utf8)

        // Dashboard's Focus moment applies through the shared entry point.
        let focusCase = try XCTUnwrap(dashboard.range(of: "case .focusSlot(let slotID):"))
        let afterCase = dashboard[focusCase.upperBound...].prefix(240)
        XCTAssertTrue(afterCase.contains("setFocusWallpaper(fallbackSlot: slotID)"), String(afterCase))

        // Every meeting-time apply in the engine uses the same entry point,
        // and the entry point is the only reader of the candidate resolution.
        XCTAssertEqual(manager.components(separatedBy: "setFocusWallpaper(fallbackSlot: resolvedSlot)").count - 1, 3)
        XCTAssertEqual(manager.components(separatedBy: "focusWallpaperCandidates(fallbackSlot:").count - 1, 2,
                       "declaration plus its single use in setFocusWallpaper")
        XCTAssertFalse(manager.contains("ignoreMood"), "the unread parameter is gone")
        XCTAssertFalse(dashboard.contains("ignoreMood"))
    }
}
